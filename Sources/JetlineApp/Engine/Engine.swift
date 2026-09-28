import Foundation
import GRDB
import Observation

/// The headless half of Jetline: repositories, worktree workspaces, agent
/// chats and terminals, git fast paths, run/setup scripts, PR tracking and
/// persistence. Runs in-process in the Mac app (local mode) or inside
/// `jetlined` on a remote host; either way clients drive it only through
/// `EngineServer`.
///
/// Nothing here presents UI. Where the old in-app logic asked the user
/// something (override a worktree holding a branch) it now returns a result
/// the client turns into a prompt, and errors propagate to the request that
/// caused them.
///
/// Per-workspace state lives in `EngineWorkspace`, looked up through
/// `workspaceState(for:)`; process-backed parts of it exist while the
/// workspace is open. Opening (activation) is client-driven, but closing
/// isn't tied to a client: agents keep running when every client
/// disconnects, which is the point of running the engine remotely.
@MainActor
@Observable
final class Engine {
    nonisolated static let repositoryBaseWorkspacePrefix = "repo-base:"

    private(set) var repositories: [Repository] = []
    private(set) var workspacesByRepo: [String: [Workspace]] = [:]
    private(set) var settings = AppSettings()
    /// Per-repo GitHub metadata (owner/name + allowed merge methods).
    private(set) var repoMetadataByRepo: [String: RepoIdentifier] = [:]
    var prTrackerStatus: PRTrackerStatus = .ok
    /// Unix socket the agent tools' MCP server reaches the engine on. Set
    /// by whoever listens there; `nil` means agents get no Jetline tools.
    @ObservationIgnored var agentToolsSocket: String?
    let rateLimits = AgentRateLimits()
    let activityLog = ActivityLog()

    @ObservationIgnored private var workspaceStates: [String: EngineWorkspace] = [:]
    @ObservationIgnored private var watchers: [String: WorktreeWatcher] = [:]
    /// Focus per client connection: which workspace each one shows.
    @ObservationIgnored private var focusByClient: [Int: String] = [:]

    // MARK: Idle pausing

    /// Last sign of life per workspace: focus, a session spawn, or a
    /// filesystem tick from its worktree.
    @ObservationIgnored private var workspaceLastActivity: [String: Date] = [:]
    /// Workspaces whose watcher the idle sweep stopped. Focusing one wakes it.
    @ObservationIgnored private var pausedWorkspaces: Set<String> = []
    @ObservationIgnored private var idleSweepTask: Task<Void, Never>?
    /// Untouched for this long → the workspace is paused: its watcher stops
    /// and it drops out of per-workspace poll work. Sessions and PTYs stay
    /// alive — output from a still-working agent hits the worktree and
    /// re-bumps activity before the sweep fires.
    private static let idlePauseThreshold: TimeInterval = 15 * 60

    @ObservationIgnored private var diffRefreshTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var diffRefreshQueued: Set<String> = []
    @ObservationIgnored private(set) lazy var prTracker: PRTracker = PRTracker(state: self)
    @ObservationIgnored private(set) lazy var conversationStore: PRConversationLoader = PRConversationLoader(state: self)
    @ObservationIgnored private var hasLoaded = false

    // MARK: Hooks for the server

    /// A workspace's state object came into existence (the server starts
    /// publishing it).
    @ObservationIgnored var onWorkspaceStateCreated: ((EngineWorkspace) -> Void)?
    @ObservationIgnored var onWorkspaceStateRemoved: ((String) -> Void)?
    /// A chat finished a turn or is waiting on the user.
    @ObservationIgnored var onAttention: ((ChatEngine, Bool) -> Void)?
    /// A background failure worth telling the user about.
    @ObservationIgnored var onError: ((String) -> Void)?

    init() {}

    /// Get-or-create the state for `id`. For a workspace that no longer
    /// exists (work finishing after a delete: a diff refresh, a PR poll in
    /// flight) this hands back a throwaway state instead of registering and
    /// publishing a ghost.
    func workspaceState(for id: String) -> EngineWorkspace {
        if let existing = workspaceStates[id] { return existing }
        let new = EngineWorkspace(id: id)
        guard workspaceById(id) != nil else { return new }
        workspaceStates[id] = new
        onWorkspaceStateCreated?(new)
        return new
    }

    var allWorkspaceStates: [EngineWorkspace] { Array(workspaceStates.values) }

    // MARK: - Load

    /// Idempotent.
    func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            settings = try SettingsStore.load()
            let repos = try Repositories.all()
            repositories = repos
            for r in repos {
                workspacesByRepo[r.id] = (try? Workspaces.forRepository(r.id)) ?? []
            }
            // Hydrate PR snapshots from disk so clients paint stale-but-known
            // state immediately. The tracker overwrites these as fresh data
            // lands.
            if let cached = try? PRSnapshots.loadAll() {
                for (wsId, snap) in cached {
                    workspaceState(for: wsId).pr = snap
                }
            }
        } catch {
            activityLog.record(.error, "Engine load error: \(error)")
        }
        prTracker.sync()
        startIdleSweep()
    }

    // MARK: - Focus & idle pausing

    func setFocus(client: Int, workspaceId: String?) {
        if let workspaceId {
            focusByClient[client] = workspaceId
            wakeIfPaused(workspaceId)
            noteWorkspaceActivity(workspaceId)
        } else {
            focusByClient.removeValue(forKey: client)
        }
    }

    func isFocused(_ id: String) -> Bool {
        focusByClient.values.contains(id)
    }

    /// Awake = worth spending per-workspace background work on (branch
    /// reconciliation, ahead/behind, diff refreshes). Focused always counts;
    /// otherwise an armed watcher is the signal.
    func isWorkspaceAwake(_ id: String) -> Bool {
        isFocused(id) || watchers[id] != nil
    }

    private func wakeIfPaused(_ id: String) {
        guard pausedWorkspaces.contains(id) else { return }
        prTracker.kick(workspaceId: id)
        activityLog.record(.lifecycle, "Woke idle workspace", repoId: workspaceById(id)?.repositoryId, workspaceId: id)
    }

    private func noteWorkspaceActivity(_ id: String) {
        workspaceLastActivity[id] = Date()
        pausedWorkspaces.remove(id)
    }

    private func startIdleSweep() {
        guard idleSweepTask == nil else { return }
        idleSweepTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.pauseIdleWorkspaces()
            }
        }
    }

    private func pauseIdleWorkspaces() {
        let cutoff = Date().addingTimeInterval(-Self.idlePauseThreshold)
        for (id, watcher) in watchers {
            guard !isFocused(id),
                  (workspaceLastActivity[id] ?? .distantPast) < cutoff
            else { continue }
            watcher.stop()
            watchers.removeValue(forKey: id)
            pausedWorkspaces.insert(id)
            activityLog.record(.lifecycle, "Paused idle workspace", repoId: workspaceById(id)?.repositoryId, workspaceId: id)
        }
    }

    // MARK: - Repositories

    func addRepository(path rawPath: String) async throws -> Repository {
        let path = Self.expandTilde(rawPath)
        guard await WorktreeOps.isGitRepo(at: path) else {
            throw WireError("Not a git repository: \(path)")
        }
        if let existing = repositories.first(where: { $0.path == path }) {
            return existing
        }
        let defaultBranch = (try? await WorktreeOps.defaultBranch(at: path)) ?? "main"
        let name = WorktreeOps.detectName(at: path)
        let repo = try Repositories.add(name: name, path: path, defaultBranch: defaultBranch)
        repositories.insert(repo, at: 0)
        workspacesByRepo[repo.id] = []
        activityLog.record(.lifecycle, "Added repository \(repo.name)", repoId: repo.id)
        prTracker.sync()
        return repo
    }

    func removeRepository(_ id: String) {
        let repo = repositories.first(where: { $0.id == id })
        let name = repo?.name ?? id
        if let repo {
            detachWorkspace(repositoryBaseWorkspaceId(for: repo))
        }
        if let workspaces = workspacesByRepo[id] {
            for ws in workspaces { detachWorkspace(ws.id) }
        }
        if let repo {
            // Chats have no foreign key to cascade from (see `chat_threads`).
            let workspaceIds = [repositoryBaseWorkspaceId(for: repo)] + (workspacesByRepo[id] ?? []).map(\.id)
            Task { [weak self] in
                for workspaceId in workspaceIds {
                    await self?.deleteChats(workspaceId: workspaceId, repoPath: repo.path)
                }
            }
        }
        try? Repositories.remove(id: id)
        repositories.removeAll { $0.id == id }
        workspacesByRepo.removeValue(forKey: id)
        repoMetadataByRepo.removeValue(forKey: id)
        activityLog.record(.lifecycle, "Removed repository \(name)")
        prTracker.sync()
    }

    func updateRepository(_ repo: Repository) throws {
        try Repositories.update(repo)
        if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
            repositories[idx] = repo
        }
    }

    func reorderRepositories(_ orderedIds: [String]) throws {
        guard Set(orderedIds) == Set(repositories.map(\.id)) else { return }
        let byId = Dictionary(uniqueKeysWithValues: repositories.map { ($0.id, $0) })
        repositories = orderedIds.compactMap { byId[$0] }
        try Repositories.reorder(orderedIds: orderedIds)
    }

    func reorderWorkspaces(in repoId: String, orderedIds: [String]) throws {
        guard let list = workspacesByRepo[repoId], Set(orderedIds) == Set(list.map(\.id)) else { return }
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        workspacesByRepo[repoId] = orderedIds.compactMap { byId[$0] }
        try Workspaces.reorder(orderedIds: orderedIds)
    }

    // MARK: - Workspaces

    func repositoryBaseWorkspaceId(for repo: Repository) -> String {
        Self.repositoryBaseWorkspacePrefix + repo.id
    }

    func isRepositoryBaseWorkspace(_ workspace: Workspace) -> Bool {
        workspace.id.hasPrefix(Self.repositoryBaseWorkspacePrefix)
    }

    private func repositoryBaseWorkspace(for repo: Repository) -> Workspace {
        let touchedAt = repo.lastOpenedAt ?? repo.createdAt
        return Workspace(
            id: repositoryBaseWorkspaceId(for: repo),
            repositoryId: repo.id,
            name: repo.name,
            branchName: repo.defaultBranch,
            baseBranch: repo.defaultBranch,
            worktreePath: repo.path,
            agent: settings.defaultAgent,
            createdAt: repo.createdAt,
            lastActiveAt: touchedAt
        )
    }

    /// `baseWorkspaceId` stacks the new workspace on that one: its branch
    /// starts from, and diffs and PRs against, the other workspace's branch.
    func createWorkspace(
        in repo: Repository,
        name: String,
        baseWorkspaceId: String?,
        createdBy: String? = nil,
        note: String? = nil,
        overrideExisting: Bool
    ) async throws -> API.CreateWorkspaceResult {
        let parent = baseWorkspaceId.flatMap(workspaceById).flatMap { $0.repositoryId == repo.id ? $0 : nil }
        if baseWorkspaceId != nil, parent == nil {
            throw WireError("The workspace to stack on no longer exists.")
        }
        let baseBranch = parent?.branchName ?? repo.defaultBranch
        let id = UUID().uuidString
        let (worktreePath, shortName) = allocateWorktreePath(for: repo)
        let slug = WorktreeOps.slug(name)
        let prefix = await effectiveBranchPrefix(for: repo)
        let branch = branchName(prefix: prefix, slug: slug, suffix: shortName, repo: repo)
        let agent = settings.defaultAgent

        if let collision = try await createWorktreeResolvingBranchCollision(
            in: repo,
            branchName: branch,
            overrideExisting: overrideExisting,
            operation: {
                try await WorktreeOps.create(
                    repoPath: repo.path,
                    worktreePath: worktreePath,
                    branchName: branch,
                    baseBranch: baseBranch
                )
            }
        ) {
            return collision
        }
        let now = Date()
        let ws = Workspace(
            id: id,
            repositoryId: repo.id,
            name: name,
            branchName: branch,
            baseBranch: baseBranch,
            worktreePath: worktreePath,
            agent: agent,
            createdAt: now,
            lastActiveAt: now,
            createdByWorkspaceId: createdBy,
            note: note?.nonBlank
        )
        try Workspaces.insert(ws)
        workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
        // A freshly minted local branch can't have a PR yet; seeding
        // `.absent` keeps the row from reading "Loading PR…" until the next
        // GitHub poll lands.
        applyPR(.absent, for: ws.id)
        let stackedOn = parent.map { " stacked on \($0.name)" } ?? ""
        activityLog.record(.lifecycle, "Created workspace \(name) (\(branch))\(stackedOn)", repoId: repo.id, workspaceId: ws.id)
        prTracker.kick(repoId: repo.id)
        startSetupIfNeeded(workspace: ws, repository: repo)
        return .created(ws)
    }

    /// Spin up a workspace against an existing PR's head branch, or an
    /// existing remote branch (`origin/feature`). Branch identity is kept
    /// verbatim — no prefix / slug / suffix.
    func importBranch(
        in repo: Repository,
        remoteRef: String?,
        pullRequest: PRSummary?,
        name: String,
        createdBy: String? = nil,
        note: String? = nil,
        overrideExisting: Bool
    ) async throws -> API.CreateWorkspaceResult {
        let branchName: String
        let baseBranch: String
        if let pullRequest {
            branchName = pullRequest.headRefName
            baseBranch = pullRequest.baseRefName
        } else if let remoteRef {
            branchName = repo.localName(forRemoteRef: remoteRef)
            baseBranch = repo.defaultBranch
        } else {
            throw WireError("Nothing to import.")
        }
        let id = UUID().uuidString
        let (worktreePath, _) = allocateWorktreePath(for: repo)
        let agent = settings.defaultAgent
        if let collision = try await createWorktreeResolvingBranchCollision(
            in: repo,
            branchName: branchName,
            overrideExisting: overrideExisting,
            operation: {
                try await WorktreeOps.importExisting(
                    repoPath: repo.path,
                    worktreePath: worktreePath,
                    branchName: branchName,
                    remote: repo.remoteOrigin
                )
            }
        ) {
            return collision
        }

        let now = Date()
        let ws = Workspace(
            id: id,
            repositoryId: repo.id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            pullRequestNumber: pullRequest?.number,
            pullRequestURL: pullRequest?.url,
            worktreePath: worktreePath,
            agent: agent,
            createdAt: now,
            lastActiveAt: now,
            createdByWorkspaceId: createdBy,
            note: note?.nonBlank
        )
        do {
            try Workspaces.insert(ws)
        } catch {
            // Worktree was created; the DB insert is the only thing that
            // failed. Tear the worktree down again so we don't leak it. The
            // local branch is the user's, not ours — leave it for a retry.
            try? await WorktreeOps.remove(
                repoPath: repo.path,
                worktreePath: worktreePath,
                branchName: nil,
                force: true
            )
            throw error
        }
        workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
        activityLog.record(.lifecycle, "Imported branch \(branchName) as workspace \(name)", repoId: repo.id, workspaceId: ws.id)
        prTracker.kick(repoId: repo.id)
        startSetupIfNeeded(workspace: ws, repository: repo)
        return .created(ws)
    }

    /// Runs `operation`. A `branchInUse` collision comes back as a result
    /// for the client to confirm, unless `overrideExisting` already says to
    /// force-remove the offending worktree.
    private func createWorktreeResolvingBranchCollision(
        in repo: Repository,
        branchName: String,
        overrideExisting: Bool,
        operation: () async throws -> Void
    ) async throws -> API.CreateWorkspaceResult? {
        do {
            try await operation()
            return nil
        } catch WorktreeOps.ImportError.branchInUse(branch: let branch, byPath: let path) {
            guard overrideExisting else {
                let dirty = await DiffComputer.hasUncommittedChanges(worktreePath: path)
                return .branchInUse(branch: branch, path: path, hasUncommittedChanges: dirty)
            }
            deleteWorkspaceRecordsForOverriddenWorktree(repoId: repo.id, branchName: branch, worktreePath: path)
            try await WorktreeOps.remove(repoPath: repo.path, worktreePath: path, branchName: branch, force: true)
            activityLog.record(.lifecycle, "Overrode existing worktree for \(branch)", repoId: repo.id)
            try await operation()
            return nil
        }
    }

    private func deleteWorkspaceRecordsForOverriddenWorktree(repoId: String, branchName: String, worktreePath: String) {
        let matches = (workspacesByRepo[repoId] ?? []).filter {
            $0.worktreePath == worktreePath || $0.branchName == branchName
        }
        guard !matches.isEmpty else { return }
        let ids = Set(matches.map(\.id))
        let repoPath = repositories.first(where: { $0.id == repoId })?.path
        for ws in matches {
            detachWorkspace(ws.id)
            Task { [weak self] in await self?.deleteChats(workspaceId: ws.id, repoPath: repoPath) }
            try? Workspaces.delete(id: ws.id)
            activityLog.record(.lifecycle, "Deleted workspace \(ws.name) because its worktree was overridden", repoId: repoId, workspaceId: ws.id)
        }
        workspacesByRepo[repoId]?.removeAll { ids.contains($0.id) }
        prTracker.sync()
    }

    /// Spawn the repo's setup script for a fresh workspace. Its terminal is
    /// what the run panel shows first.
    private func startSetupIfNeeded(workspace: Workspace, repository: Repository) {
        guard let script = repository.trimmedSetupScript else { return }
        let setup = ScriptRun(kind: .setup, workspaceId: workspace.id, settings: { [weak self] in self?.settings ?? AppSettings() })
        workspaceState(for: workspace.id).setup = setup
        setup.start(script: script, cwd: workspace.worktreePath, env: ScriptRunner.defaultEnv(repoPath: repository.path))
    }

    /// Remove the worktree and its branch, the workspace's chats and its row.
    func deleteWorkspace(_ workspace: Workspace) async {
        // Stop tabs/run/setup first; otherwise they can keep writing to a
        // worktree that is about to disappear. The row goes before the first
        // await so no client can re-activate it meanwhile.
        detachWorkspace(workspace.id)
        workspacesByRepo[workspace.repositoryId]?.removeAll { $0.id == workspace.id }
        let repo = repositories.first(where: { $0.id == workspace.repositoryId })
        if let repo {
            // The branch goes with the worktree, so anything stacked on it
            // moves down onto what it was stacked on. GitHub retargets their
            // PRs the same way when this one merges.
            for child in WorkspaceStacks.children(of: workspace, in: workspacesByRepo[repo.id] ?? [], repo: repo) {
                updateWorkspaceBaseBranch(workspace.baseBranch, for: child.id)
            }
            try? await WorktreeOps.remove(
                repoPath: repo.path,
                worktreePath: workspace.worktreePath,
                branchName: workspace.branchName,
                force: true
            )
        }
        await deleteChats(workspaceId: workspace.id, repoPath: repo?.path)
        try? Workspaces.delete(id: workspace.id)
        activityLog.record(.lifecycle, "Deleted workspace \(workspace.name)", repoId: workspace.repositoryId, workspaceId: workspace.id)
        prTracker.sync()
    }

    /// Drop a workspace's chats and their checkpoint refs, which live in the
    /// shared repository and would outlive the worktree.
    private func deleteChats(workspaceId: String, repoPath: String?) async {
        if let repoPath {
            for threadId in ChatStore.threadIds(workspaceId: workspaceId) {
                await Checkpointer.deleteRefs(worktree: repoPath, thread: threadId)
            }
        }
        ChatStore.deleteThreads(workspaceId: workspaceId)
    }

    /// The prefix prepended to a fresh workspace's branch name.
    private func effectiveBranchPrefix(for repo: Repository) async -> String {
        let mode: BranchPrefixMode
        if let raw = repo.branchPrefixMode, let resolved = BranchPrefixMode(rawValue: raw) {
            mode = resolved
        } else {
            mode = repo.branchPrefix?.nonBlank == nil ? .username : .custom
        }
        switch mode {
        case .username:
            let slug = await WorktreeOps.usernameSlug(at: repo.path)
            return slug.isEmpty ? "" : slug + "/"
        case .custom:
            return repo.branchPrefix?.nonBlank ?? ""
        case .none:
            return ""
        }
    }

    /// `~/.jetline/worktrees/<repo-slug>/<star>`. `shortName` is the star
    /// component, reused as the branch suffix.
    private func allocateWorktreePath(for repo: Repository) -> (path: String, shortName: String) {
        let folder = Database.worktreesDirectory
            .appendingPathComponent(repo.worktreeFolderName, isDirectory: true)
        let shortName = WorktreeNamer.allocate(in: folder)
        return (folder.appendingPathComponent(shortName, isDirectory: true).path, shortName)
    }

    private func branchName(prefix: String, slug: String, suffix: String, repo: Repository) -> String {
        let base = "\(prefix)\(slug)"
        return repo.addUniqueBranchSuffix ? "\(base)-\(suffix)" : base
    }

    // MARK: - Activation

    /// Bring a workspace's runtime up: its chats or a first tab, the file
    /// watcher, a diff refresh. Idempotent.
    func activateWorkspace(_ id: String, terminalSize: TerminalSize?) -> API.ActivateResult {
        guard let ws = workspaceById(id) else { return .missing }
        noteWorkspaceActivity(id)
        persistSelectionTouch(id)
        guard worktreeExists(for: ws) else {
            handleMissingWorktree(ws)
            return .missing
        }
        workspaceState(for: id).isOpen = true
        ensureSessionExists(for: ws, terminalSize: terminalSize)
        startWatcher(for: ws)
        Task { await refreshDiff(for: ws) }
        return .ready
    }

    private nonisolated func persistSelectionTouch(_ id: String) {
        Task.detached(priority: .utility) {
            if id.hasPrefix(Self.repositoryBaseWorkspacePrefix) {
                let repoId = String(id.dropFirst(Self.repositoryBaseWorkspacePrefix.count))
                try? Repositories.touch(id: repoId)
            } else {
                try? Workspaces.touch(id: id)
            }
        }
    }

    /// The first activation of a workspace's runtime: bring back its open
    /// chats, or start a fresh tab when it has none.
    private func ensureSessionExists(for workspace: Workspace, terminalSize: TerminalSize?) {
        let ws = workspaceState(for: workspace.id)
        guard !ws.hasAgentTabs else { return }
        let restored = ChatStore.openThreads(workspaceId: workspace.id)
        if !restored.isEmpty {
            for record in restored {
                let chat = ChatEngine(
                    record: record,
                    cwd: workspace.worktreePath,
                    rateLimits: rateLimits,
                    executableResolver: resolveAgentExecutable
                )
                attach(chat, to: workspace.id)
            }
            // The chat the client will show first starts its agent now.
            ws.chats.last?.connectIfNeeded()
            return
        }
        _ = startNewSession(for: workspace, agent: workspace.agent, terminalSize: terminalSize)
    }

    /// Open a new tab for `agent` in whichever interface the settings pick.
    func startNewSession(for workspace: Workspace, agent: Workspace.AgentKind, terminalSize: TerminalSize?) -> OpenedTab {
        if settings.opensChat(for: agent), let provider = AgentProviderKind(agent: agent) {
            return .chat(startNewChat(for: workspace, provider: provider).summary)
        }
        return .terminal(startNewTerminal(for: workspace, agent: agent, terminalSize: terminalSize).info)
    }

    @discardableResult
    func startNewTerminal(
        for workspace: Workspace,
        agent: Workspace.AgentKind,
        launchArgs: [String] = [],
        initialPrompt: String? = nil,
        terminalSize: TerminalSize?
    ) -> EngineTerminal {
        noteWorkspaceActivity(workspace.id)
        let ws = workspaceState(for: workspace.id)
        ws.isOpen = true
        let toolArgs = agentToolsLaunch(for: workspace.id)?.args(for: agent) ?? []
        let terminal = EngineTerminal(
            workspaceId: workspace.id,
            agent: agent,
            cwd: workspace.worktreePath,
            launch: .agent(initialPrompt: initialPrompt, launchArgs: toolArgs + launchArgs),
            settings: { [weak self] in self?.settings ?? AppSettings() }
        )
        ws.terminals.append(terminal)
        terminal.start(size: terminalSize)
        return terminal
    }

    func terminal(id: String) -> EngineTerminal? {
        for ws in workspaceStates.values {
            if let t = ws.terminals.first(where: { $0.id == id }) { return t }
            if let t = ws.run?.terminal, t.id == id { return t }
            if let t = ws.setup?.terminal, t.id == id { return t }
        }
        return nil
    }

    /// Close a terminal tab: terminate its process and drop it.
    func closeTerminal(_ id: String) {
        for ws in workspaceStates.values {
            guard let idx = ws.terminals.firstIndex(where: { $0.id == id }) else { continue }
            let terminal = ws.terminals.remove(at: idx)
            terminal.terminate()
            return
        }
    }

    // MARK: - Chats

    /// Open a native chat. `prompt` is sent as the first message.
    @discardableResult
    func startNewChat(for workspace: Workspace, provider: AgentProviderKind, prompt: String? = nil) -> ChatEngine {
        noteWorkspaceActivity(workspace.id)
        workspaceState(for: workspace.id).isOpen = true
        let chat = ChatEngine(
            workspaceId: workspace.id,
            cwd: workspace.worktreePath,
            provider: provider,
            model: settings.chatModel(for: provider),
            effort: settings.chatEffort(for: provider),
            runtimeMode: settings.chatRuntimeMode,
            rateLimits: rateLimits,
            executableResolver: resolveAgentExecutable
        )
        attach(chat, to: workspace.id)
        chat.connectIfNeeded()
        if let prompt { chat.send(text: prompt) }
        return chat
    }

    /// Bring a closed chat back as a tab.
    func reopenChat(threadId: String, in workspace: Workspace) -> ChatEngine? {
        let ws = workspaceState(for: workspace.id)
        if let open = ws.chats.first(where: { $0.id == threadId }) { return open }
        guard let record = ChatStore.thread(id: threadId) else { return nil }
        ChatStore.setClosed(record.id, closed: false)
        ws.isOpen = true
        let chat = ChatEngine(record: record, cwd: workspace.worktreePath, rateLimits: rateLimits, executableResolver: resolveAgentExecutable)
        attach(chat, to: workspace.id)
        return chat
    }

    private func attach(_ chat: ChatEngine, to workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        chat.agentTools = agentToolsLaunch(for: workspaceId)
        ws.chats.append(chat)
        chat.onTurnFinished = { [weak self] chat in
            guard let self, let workspace = self.workspaceById(chat.workspaceId) else { return }
            self.noteWorkspaceActivity(chat.workspaceId)
            Task { await self.refreshDiff(for: workspace) }
        }
        chat.onAttention = { [weak self] chat in
            self?.onAttention?(chat, chat.activity == .needsInput)
        }
    }

    func chat(id: String) -> ChatEngine? {
        for ws in workspaceStates.values {
            if let chat = ws.chats.first(where: { $0.id == id }) { return chat }
        }
        return nil
    }

    /// Close a chat tab: stop its process and mark the thread closed.
    func closeChat(_ chatId: String) {
        for ws in workspaceStates.values {
            guard let idx = ws.chats.firstIndex(where: { $0.id == chatId }) else { continue }
            let chat = ws.chats.remove(at: idx)
            chat.close()
            return
        }
    }

    /// Continue a chat in the agent's own TUI: stop the chat's process (two
    /// writers on one transcript would fork it) and open a terminal tab
    /// resuming the same conversation.
    func openChatInTerminal(_ chat: ChatEngine, terminalSize: TerminalSize?) -> EngineTerminal? {
        guard let args = chat.terminalResumeArgs, let workspace = workspaceById(chat.workspaceId) else { return nil }
        chat.disconnect()
        return startNewTerminal(for: workspace, agent: chat.provider.agentKind, launchArgs: args, terminalSize: terminalSize)
    }

    /// Resolve the CLI for a chat: the configured path, else a PATH probe.
    private func resolveAgentExecutable(_ provider: AgentProviderKind) async -> String? {
        let configured = provider == .claude ? settings.claudeBinaryPath : settings.codexBinaryPath
        if let configured, !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        return await AgentLauncher.resolveOnPath(provider.agentKind.executableName)
    }

    /// Stop every chat's agent process and every terminal. Chats run in
    /// their own sessions, so nothing else would signal them on quit.
    func shutdown() async {
        await withTaskGroup(of: Void.self) { group in
            for ws in workspaceStates.values {
                for chat in ws.chats {
                    group.addTask { await chat.shutdown() }
                }
            }
        }
        // Terminals: wait (briefly) until their process groups are really
        // gone — the SIGHUP / SIGKILL escalation runs on their io queues and
        // wouldn't happen at all if the process exited first.
        var all: [EngineTerminal] = []
        for ws in workspaceStates.values {
            all += ws.terminals
            if let t = ws.run?.terminal { all.append(t) }
            if let t = ws.setup?.terminal { all.append(t) }
        }
        let remaining = Countdown(all.count)
        for terminal in all {
            terminal.terminate { remaining.decrement() }
        }
        let deadline = ContinuousClock.now + .seconds(4)
        while remaining.value > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Git actions

    /// Open a fresh tab with the configured agent and the rendered prompt as
    /// its first message.
    func startGitActionSession(for workspace: Workspace, action: GitAction, terminalSize: TerminalSize?) -> OpenedTab? {
        let agent = resolveAgent(for: action)
        let repo = repositories.first(where: { $0.id == workspace.repositoryId })
        guard let template = GitActionPrompts.template(for: action, repository: repo, settings: settings) else { return nil }
        let pr: PullRequest?
        let checks: [CheckRun]
        if case let .loaded(pull, runs) = workspaceState(for: workspace.id).pr {
            pr = pull
            checks = runs
        } else {
            pr = nil
            checks = []
        }
        let prompt = GitActionPrompts.render(template, workspace: workspace, baseRef: baseRef(for: workspace), pr: pr, checks: checks)
        if settings.opensChat(for: agent), let provider = AgentProviderKind(agent: agent) {
            return .chat(startNewChat(for: workspace, provider: provider, prompt: prompt).summary)
        }
        return .terminal(startNewTerminal(for: workspace, agent: agent, initialPrompt: prompt, terminalSize: terminalSize).info)
    }

    /// review → reviewAgent → defaultAgent; everything else → gitAgent →
    /// defaultAgent. `.shell` can't act on a prompt, so it maps to Claude.
    private func resolveAgent(for action: GitAction) -> Workspace.AgentKind {
        let preferred: Workspace.AgentKind? = action.usesReviewAgent ? settings.reviewAgent : settings.gitAgent
        let chosen = preferred ?? settings.defaultAgent
        return chosen == .shell ? .claude : chosen
    }

    /// `gh pr merge` with the picked strategy (no agent involved). Persists
    /// the method as the repo's default on success.
    func performMerge(for workspace: Workspace, method: MergeMethod) async throws {
        let ws = workspaceState(for: workspace.id)
        // One git action at a time: a second click (or client) would race it.
        guard case let .loaded(pr, _) = ws.pr, ws.runningGitAction == nil else { return }
        ws.runningGitAction = .mergePR
        defer { ws.runningGitAction = nil }
        activityLog.record(.gitAction, "Merging PR #\(pr.number) (\(method.rawValue))", repoId: workspace.repositoryId, workspaceId: workspace.id)
        do {
            try await GitHubRunner.merge(pr, method: method, repo: repoMetadataByRepo[workspace.repositoryId], cwd: workspace.worktreePath)
        } catch {
            activityLog.record(.error, "Merge failed for PR #\(pr.number): \(error.localizedDescription)", repoId: workspace.repositoryId, workspaceId: workspace.id)
            throw WireError(error.localizedDescription)
        }
        activityLog.record(.gitAction, "Merged PR #\(pr.number)", repoId: workspace.repositoryId, workspaceId: workspace.id)
        rememberMergeMethod(method, repoId: workspace.repositoryId)
        prTracker.kick(workspaceId: workspace.id)
    }

    /// Queue (or cancel) an auto-merge: GitHub lands the PR once every
    /// protection rule is satisfied.
    func setAutoMerge(for workspace: Workspace, enabling: Bool, method: MergeMethod?) async throws {
        let ws = workspaceState(for: workspace.id)
        guard case let .loaded(pr, _) = ws.pr, !ws.isTogglingAutoMerge else { return }
        ws.isTogglingAutoMerge = true
        defer { ws.isTogglingAutoMerge = false }
        let verb = enabling ? "Enabling" : "Cancelling"
        activityLog.record(.gitAction, "\(verb) auto-merge on PR #\(pr.number)", repoId: workspace.repositoryId, workspaceId: workspace.id)
        do {
            if enabling, let method {
                try await GitHubRunner.enableAutoMerge(pr.number, method: method, cwd: workspace.worktreePath)
            } else {
                try await GitHubRunner.disableAutoMerge(pr.number, cwd: workspace.worktreePath)
            }
        } catch {
            activityLog.record(
                .error,
                "Auto-merge \(enabling ? "enable" : "cancel") failed for PR #\(pr.number): \(error.localizedDescription)",
                repoId: workspace.repositoryId,
                workspaceId: workspace.id
            )
            throw WireError(error.localizedDescription)
        }
        activityLog.record(
            .gitAction,
            enabling ? "Auto-merge enabled on PR #\(pr.number)" : "Auto-merge cancelled on PR #\(pr.number)",
            repoId: workspace.repositoryId,
            workspaceId: workspace.id
        )
        if enabling, let method { rememberMergeMethod(method, repoId: workspace.repositoryId) }
        prTracker.kick(workspaceId: workspace.id)
    }

    private func rememberMergeMethod(_ method: MergeMethod, repoId: String) {
        guard var repo = repositories.first(where: { $0.id == repoId }), repo.lastMergeMethod != method.rawValue else { return }
        repo.lastMergeMethod = method.rawValue
        try? updateRepository(repo)
    }

    /// Why a git fast path didn't finish. Anything partial was undone.
    enum FastPathFailure: LocalizedError {
        /// Another git action is already running in the workspace.
        case busy
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "Another git action is already running in this workspace."
            case let .failed(message): return message
            }
        }
    }

    /// `Rebase` / `Pull updates` from the toolbar: the fast path, handing
    /// off to the agent flow (whose tab is returned) when it can't finish
    /// on its own. Any other action goes straight to the agent.
    func performFastPath(_ action: GitAction, for workspace: Workspace, terminalSize: TerminalSize?) async -> OpenedTab? {
        let outcome: Result<Void, FastPathFailure>
        switch action {
        case .rebaseOnMain: outcome = await rebase(workspace)
        case .pullUpdates: outcome = await pull(workspace)
        default: return startGitActionSession(for: workspace, action: action, terminalSize: terminalSize)
        }
        switch outcome {
        case .success, .failure(.busy):
            return nil
        case .failure:
            return startGitActionSession(for: workspace, action: action, terminalSize: terminalSize)
        }
    }

    /// `git fetch` + `git rebase --autostash` onto the base (`--onto` a new
    /// one when `onto` is set, replaying only the commits above `upstream`),
    /// then a `--force-with-lease` push when the branch is on the remote.
    func rebase(
        _ workspace: Workspace,
        onto: String? = nil,
        upstream: String? = nil
    ) async -> Result<Void, FastPathFailure> {
        let base = upstream ?? baseRef(for: workspace)
        let target = onto ?? base
        let hasRemote = workspaceState(for: workspace.id).branchPosition.remoteTrackingExists
        return await withFastPath(.rebaseOnMain, workspace, "Rebasing on \(target)") { repo, cwd in
            await BranchPositionOps.fetch(repoPath: cwd, remote: repo.remoteOrigin)
            let args = onto.map { ["rebase", "--autostash", "--onto", $0, base] } ?? ["rebase", "--autostash", base]
            guard (try? await GitRunner.run(args, cwd: cwd))?.success == true else {
                return "Rebasing onto \(target) hit conflicts, so it was undone. Resolve them with git in the worktree."
            }
            guard hasRemote else { return nil }
            let push = try? await GitRunner.run(["push", "--force-with-lease", repo.remoteOrigin, workspace.branchName], cwd: cwd)
            return push?.success == true ? nil : "Rebased locally, but the push failed: \(push?.stderr.nonBlank ?? "unknown error")"
        }
    }

    /// `git pull --rebase --autostash` of the branch's own remote commits.
    func pull(_ workspace: Workspace) async -> Result<Void, FastPathFailure> {
        await withFastPath(.pullUpdates, workspace, "Pulling \(workspace.branchName)") { repo, cwd in
            let result = try? await GitRunner.run(
                ["pull", "--rebase", "--autostash", repo.remoteOrigin, workspace.branchName],
                cwd: cwd
            )
            return result?.success == true ? nil : "Pulling \(workspace.branchName) failed and was undone: \(result?.stderr.nonBlank ?? "unknown error")"
        }
    }

    /// One git fast path at a time per workspace, with the index marked as
    /// being written. `body` returns why it failed, or `nil`; a failure
    /// aborts any rebase it left half done.
    private func withFastPath(
        _ action: GitAction,
        _ workspace: Workspace,
        _ description: String,
        body: (Repository, String) async -> String?
    ) async -> Result<Void, FastPathFailure> {
        guard let repo = repository(id: workspace.repositoryId) else { return .failure(.failed("Unknown repository.")) }
        let ws = workspaceState(for: workspace.id)
        guard ws.runningGitAction == nil else { return .failure(.busy) }
        ws.runningGitAction = action
        defer { ws.runningGitAction = nil }
        activityLog.record(.gitAction, description, repoId: repo.id, workspaceId: workspace.id)

        let cwd = workspace.worktreePath
        WorktreeOps.beginIndexWrite(worktreePath: cwd)
        defer { WorktreeOps.endIndexWrite(worktreePath: cwd) }
        if let failure = await body(repo, cwd) {
            _ = try? await GitRunner.run(["rebase", "--abort"], cwd: cwd)
            activityLog.record(.gitAction, "\(action.displayName) stopped: \(failure)", repoId: repo.id, workspaceId: workspace.id)
            return .failure(.failed(failure))
        }
        activityLog.record(.gitAction, "\(action.displayName) completed", repoId: repo.id, workspaceId: workspace.id)
        prTracker.kick(workspaceId: workspace.id)
        await refreshDiff(for: workspace)
        return .success(())
    }

    /// Move `workspace` onto `parent` (`nil`: the default branch): rebase
    /// its own commits there, push, re-base the workspace and retarget its
    /// open PR. Refused for a loop, and for a PR in a GitHub stack, which
    /// GitHub has to unstack first. Returns a warning when only the PR
    /// retarget failed.
    func restackWorkspace(_ workspace: Workspace, onto parent: Workspace?) async throws -> String? {
        guard let repo = repository(id: workspace.repositoryId) else { throw WireError("Unknown repository.") }
        if let parent, WorkspaceStacks.isStacked(parent, onTopOf: workspace, in: workspacesByRepo[repo.id] ?? [], repo: repo) {
            throw WireError("Can't stack \(workspace.name) on itself or on a workspace above it.")
        }
        let pr: PullRequest? = {
            if case let .loaded(pr, _) = workspaceState(for: workspace.id).pr, pr.isOpen { return pr }
            return nil
        }()
        if let pr, let stack = pr.stack {
            throw WireError("PR #\(pr.number) is in GitHub stack #\(stack.number). Unstack it on GitHub first.")
        }
        let newBase = parent?.branchName ?? repo.defaultBranch
        try await rebase(workspace, onto: parent?.branchName ?? repo.remoteRef(newBase), upstream: baseRef(for: workspace)).get()
        updateWorkspaceBaseBranch(newBase, for: workspace.id)
        prTracker.kick(repoId: repo.id)
        guard let pr else { return nil }
        let base = repo.localName(forRemoteRef: newBase)
        do {
            _ = try await GitHubRunner.runGH(["pr", "edit", String(pr.number), "--base", base], cwd: workspace.worktreePath)
            return nil
        } catch {
            return "Couldn't retarget PR #\(pr.number) to \(base): \(error.localizedDescription)"
        }
    }

    // MARK: - Run script

    /// Toggle the run script. Honours the per-repo `runExclusive` flag —
    /// starting an exclusive run stops every other active runner in the
    /// same repository first, and waits until they're really gone.
    func toggleRun(for workspace: Workspace) {
        let ws = workspaceState(for: workspace.id)
        if let runner = ws.run, runner.isRunning {
            runner.stop()
            return
        }
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }),
              let script = repo.trimmedRunScript else { return }
        let peers = repo.runExclusive ? activeRunners(in: repo, excluding: workspace.id) : []
        // Drop the setup transcript so that when the run eventually exits
        // the panel falls back to the placeholder, not to "Setup complete".
        if let setup = ws.setup {
            setup.discard()
            ws.setup = nil
        }
        let runner = ws.run ?? ScriptRun(kind: .run, workspaceId: workspace.id, settings: { [weak self] in self?.settings ?? AppSettings() })
        ws.run = runner
        ws.isOpen = true
        let cwd = workspace.worktreePath
        let env = ScriptRunner.defaultEnv(repoPath: repo.path)
        guard !peers.isEmpty else {
            runner.start(script: script, cwd: cwd, env: env)
            return
        }
        runner.start(script: script, cwd: cwd, env: env) {
            await withTaskGroup(of: Void.self) { group in
                for peer in peers {
                    group.addTask { await peer.stopAndWait() }
                }
            }
        }
    }

    private func activeRunners(in repo: Repository, excluding workspaceId: String) -> [ScriptRun] {
        var peerIds = Set(workspacesByRepo[repo.id]?.map(\.id) ?? [])
        peerIds.insert(repositoryBaseWorkspaceId(for: repo))
        return workspaceStates.compactMap { otherId, peer in
            guard otherId != workspaceId, peerIds.contains(otherId),
                  let runner = peer.run, runner.isRunning else { return nil }
            return runner
        }
    }

    // MARK: - Diff & watcher

    func refreshDiff(for workspace: Workspace) async {
        let id = workspace.id
        if let running = diffRefreshTasks[id] {
            diffRefreshQueued.insert(id)
            await running.value
            return
        }
        let task = Task { [weak self] in
            await self?.performDiffRefresh(for: workspace)
            while let self, self.diffRefreshQueued.remove(id) != nil {
                await self.performDiffRefresh(for: workspace)
            }
            self?.diffRefreshTasks[id] = nil
        }
        diffRefreshTasks[id] = task
        await task.value
    }

    private func performDiffRefresh(for workspace: Workspace) async {
        guard worktreeExists(for: workspace) else {
            handleMissingWorktree(workspace)
            return
        }
        // nil means the lookup itself failed (offline base / brand-new
        // repo); the combined compute then falls back to its own resolution.
        let mergeBase = try? await DiffComputer.mergeBase(worktreePath: workspace.worktreePath, baseBranch: workspace.baseBranch)
        async let combined: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .combined,
                precomputedMergeBase: mergeBase
            )
        }()
        async let localSnap: DiffSnapshot? = {
            try? await DiffComputer.compute(worktreePath: workspace.worktreePath, baseBranch: workspace.baseBranch, mode: .local)
        }()
        async let uncommitted = DiffComputer.hasUncommittedChanges(worktreePath: workspace.worktreePath)

        let ws = workspaceState(for: workspace.id)
        if let snap = await combined, ws.diff != snap { ws.diff = snap }
        if let snap = await localSnap, ws.localDiff != snap { ws.localDiff = snap }
        let dirty = await uncommitted
        if ws.hasUncommitted != dirty { ws.hasUncommitted = dirty }
    }

    /// Single write path for PR snapshots; mirrored to disk so the next
    /// launch can paint immediately. No-op writes are suppressed.
    func applyPR(_ snapshot: PRSnapshot, for workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        guard ws.pr != snapshot else { return }
        ws.pr = snapshot
        Task.detached(priority: .utility) {
            try? PRSnapshots.save(snapshot, for: workspaceId)
        }
    }

    /// Single write path for PR conversations. In-memory only.
    func applyConversation(_ snapshot: PRConversationSnapshot, for workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        guard ws.conversation != snapshot else { return }
        ws.conversation = snapshot
    }

    /// Correct stale branch metadata when the worktree or upstream branch
    /// changed outside Jetline (an agent pushed `HEAD` to a renamed remote
    /// branch before opening a PR, say).
    @discardableResult
    func updateWorkspaceBranchName(_ branchName: String, for workspaceId: String) -> Workspace? {
        guard var workspace = workspaceById(workspaceId), !isRepositoryBaseWorkspace(workspace) else { return nil }
        guard workspace.branchName != branchName else { return workspace }
        let previous = workspace.branchName
        workspace.branchName = branchName
        let hadPRIdentity = workspace.pullRequestNumber != nil || workspace.pullRequestURL != nil
        workspace.pullRequestNumber = nil
        workspace.pullRequestURL = nil
        replaceWorkspace(workspace)
        activityLog.record(.prPoll, "Reconciled branch \(previous) → \(branchName)", repoId: workspace.repositoryId, workspaceId: workspace.id)
        Task.detached(priority: .utility) {
            try? Workspaces.updateBranchName(id: workspaceId, branchName: branchName)
            if hadPRIdentity {
                try? Workspaces.updatePRIdentity(id: workspaceId, number: nil, url: nil)
            }
        }
        return workspace
    }

    func renameWorkspace(_ workspaceId: String, to name: String) {
        updateWorkspace(workspaceId, Workspace.Columns.name.set(to: name)) { $0.name = name }
    }

    func setWorkspaceNote(_ workspaceId: String, note: String?) {
        updateWorkspace(workspaceId, Workspace.Columns.note.set(to: note)) { $0.note = note }
    }

    /// Move a workspace onto another base (restacking, or following a PR
    /// GitHub retargeted). The diff is against the base, so it's redone.
    func updateWorkspaceBaseBranch(_ baseBranch: String, for workspaceId: String) {
        guard let previous = workspaceById(workspaceId)?.baseBranch,
              let workspace = updateWorkspace(workspaceId, Workspace.Columns.baseBranch.set(to: baseBranch), { $0.baseBranch = baseBranch }) else { return }
        activityLog.record(.lifecycle, "Base of \(workspace.name) moved \(previous) → \(baseBranch)", repoId: workspace.repositoryId, workspaceId: workspace.id)
        if workspaceState(for: workspaceId).isOpen {
            Task { await refreshDiff(for: workspace) }
        }
    }

    /// Apply `change` to the workspace and persist `column`. Returns the
    /// updated workspace, or `nil` when nothing changed (or it's the
    /// repository's own checkout, which has no row).
    @discardableResult
    private func updateWorkspace(
        _ workspaceId: String,
        _ column: ColumnAssignment,
        _ change: (inout Workspace) -> Void
    ) -> Workspace? {
        guard let old = workspaceById(workspaceId), !isRepositoryBaseWorkspace(old) else { return nil }
        var workspace = old
        change(&workspace)
        guard workspace != old else { return nil }
        replaceWorkspace(workspace)
        // Not `Sendable`, but handed over whole: nothing here touches it after.
        nonisolated(unsafe) let column = column
        Task.detached(priority: .utility) { try? Workspaces.update(id: workspaceId, column) }
        return workspace
    }

    /// Follow the base GitHub reports for an open PR. The default branch
    /// keeps the repository's spelling of it (`main` vs `origin/main`).
    func syncBaseBranch(withPRBase prBase: String, for workspaceId: String) {
        guard let workspace = workspaceById(workspaceId),
              let repo = repository(id: workspace.repositoryId),
              repo.localName(forRemoteRef: workspace.baseBranch) != prBase else { return }
        let base = prBase == repo.localName(forRemoteRef: repo.defaultBranch) ? repo.defaultBranch : prBase
        updateWorkspaceBaseBranch(base, for: workspaceId)
    }

    /// See `WorkspaceStacks.baseRef`.
    func baseRef(for workspace: Workspace) -> String {
        guard let repo = repository(id: workspace.repositoryId) else { return workspace.baseBranch }
        return WorkspaceStacks.baseRef(for: workspace, in: workspacesByRepo[repo.id] ?? [], repo: repo)
    }

    /// Persist a durable PR identity once a poll or import has found it.
    func applyPRIdentity(number: Int, url: String, for workspaceId: String) {
        guard var workspace = workspaceById(workspaceId), !isRepositoryBaseWorkspace(workspace) else { return }
        guard workspace.pullRequestNumber != number || workspace.pullRequestURL != url else { return }
        workspace.pullRequestNumber = number
        workspace.pullRequestURL = url
        replaceWorkspace(workspace)
        Task.detached(priority: .utility) {
            try? Workspaces.updatePRIdentity(id: workspaceId, number: number, url: url)
        }
    }

    /// User-initiated refresh: mark the workspace as awaiting a poll result
    /// (drives the spinner) and wake the tracker.
    func requestPRRefresh(workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        if !ws.isRefreshingPR { ws.isRefreshingPR = true }
        activityLog.record(.gitAction, "User requested PR refresh", repoId: workspaceById(workspaceId)?.repositoryId, workspaceId: workspaceId)
        prTracker.kick(workspaceId: workspaceId)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.endPRRefresh(workspaceId: workspaceId)
        }
    }

    func endPRRefresh(workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        if ws.isRefreshingPR { ws.isRefreshingPR = false }
    }

    func applyRepoMetadata(_ metadata: RepoIdentifier, for repoId: String) {
        if repoMetadataByRepo[repoId] != metadata {
            repoMetadataByRepo[repoId] = metadata
        }
    }

    func applyBranchPosition(_ position: BranchPosition, for workspaceId: String) {
        let ws = workspaceState(for: workspaceId)
        if ws.branchPosition != position { ws.branchPosition = position }
    }

    private func startWatcher(for workspace: Workspace) {
        guard worktreeExists(for: workspace) else {
            handleMissingWorktree(workspace)
            return
        }
        guard watchers[workspace.id] == nil else { return }
        let id = workspace.id
        let worktreePath = workspace.worktreePath
        // Resolve the worktree's git-dir so it's watched too: `git commit`
        // mutates `<repo>/.git/worktrees/<id>/{HEAD,index}` outside the
        // worktree path.
        Task { [weak self] in
            guard let self else { return }
            let gitDir = await WorktreeOps.gitDir(at: worktreePath)
            // A git proc killed mid-write strands `index.lock` and blocks
            // every later index write; attach is the natural recovery point.
            if let gitDir, !WorktreeOps.hasActiveIndexWrite(worktreePath: worktreePath) {
                WorktreeOps.removeStaleIndexLock(gitDir: gitDir)
            }
            guard self.watchers[id] == nil, self.workspaceById(id) != nil,
                  self.workspaceStates[id]?.isOpen == true else { return }
            var additional: [String] = []
            if let gitDir, gitDir != worktreePath { additional.append(gitDir) }
            let watcher = WorktreeWatcher(worktreePath: worktreePath, additionalPaths: additional) { [weak self] in
                guard let self, let ws = self.workspaceById(id) else { return }
                // Worktree writes count as activity — a background agent
                // still working keeps its workspace out of the idle sweep.
                self.noteWorkspaceActivity(id)
                if let gitDir, !WorktreeOps.hasActiveIndexWrite(worktreePath: worktreePath) {
                    WorktreeOps.removeStaleIndexLock(gitDir: gitDir)
                }
                Task { await self.refreshDiff(for: ws) }
                // Likely a commit or push: wake the PR tracker.
                self.prTracker.kick(workspaceId: id)
            }
            watcher.start()
            self.watchers[id] = watcher
        }
    }

    /// Stop a workspace's live runtime — sessions, watcher, run/setup —
    /// while keeping its sidebar entry and cached diff/PR state.
    func closeWorkspace(_ id: String) {
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        pausedWorkspaces.remove(id)
        if let ws = workspaceStates[id] {
            tearDownWorkspaceRuntime(ws)
        }
        removeStrandedIndexLock(workspaceId: id)
    }

    private func detachWorkspace(_ id: String) {
        closeWorkspace(id)
        if workspaceStates.removeValue(forKey: id) != nil {
            onWorkspaceStateRemoved?(id)
        }
        for client in focusByClient.keys where focusByClient[client] == id {
            focusByClient.removeValue(forKey: client)
        }
    }

    private func removeStrandedIndexLock(workspaceId: String) {
        guard let workspace = workspaceById(workspaceId) else { return }
        let worktreePath = workspace.worktreePath
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let gitDir = await WorktreeOps.gitDir(at: worktreePath) else { return }
            guard !WorktreeOps.hasActiveIndexWrite(worktreePath: worktreePath) else { return }
            WorktreeOps.removeIndexLock(gitDir: gitDir)
        }
    }

    private func tearDownWorkspaceRuntime(_ ws: EngineWorkspace) {
        for terminal in ws.terminals { terminal.terminate() }
        ws.terminals.removeAll()
        // Chats stay open in the database and come back next activation;
        // only their processes stop.
        for chat in ws.chats { chat.retire() }
        ws.chats.removeAll()
        ws.setup?.discard()
        ws.setup = nil
        ws.run?.discard()
        ws.run = nil
        ws.isOpen = false
    }

    private func worktreeExists(for workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: workspace.worktreePath)
    }

    private func handleMissingWorktree(_ workspace: Workspace) {
        guard workspaceById(workspace.id) != nil else { return }
        detachWorkspace(workspace.id)
        // The repository's own checkout going missing isn't a workspace
        // deletion; leave the repo row alone.
        guard !isRepositoryBaseWorkspace(workspace) else { return }
        let repoPath = repositories.first(where: { $0.id == workspace.repositoryId })?.path
        Task { [weak self] in await self?.deleteChats(workspaceId: workspace.id, repoPath: repoPath) }
        try? Workspaces.delete(id: workspace.id)
        workspacesByRepo[workspace.repositoryId]?.removeAll { $0.id == workspace.id }
        activityLog.record(.lifecycle, "Deleted workspace \(workspace.name) because its worktree is missing", repoId: workspace.repositoryId, workspaceId: workspace.id)
        prTracker.sync()
    }

    // MARK: - Helpers

    func workspaceById(_ id: String) -> Workspace? {
        for list in workspacesByRepo.values {
            if let ws = list.first(where: { $0.id == id }) { return ws }
        }
        if id.hasPrefix(Self.repositoryBaseWorkspacePrefix) {
            let repoId = String(id.dropFirst(Self.repositoryBaseWorkspacePrefix.count))
            if let repo = repositories.first(where: { $0.id == repoId }) {
                return repositoryBaseWorkspace(for: repo)
            }
        }
        return nil
    }

    func repository(id: String) -> Repository? {
        repositories.first { $0.id == id }
    }

    private func replaceWorkspace(_ workspace: Workspace) {
        guard var list = workspacesByRepo[workspace.repositoryId],
              let idx = list.firstIndex(where: { $0.id == workspace.id }) else { return }
        list[idx] = workspace
        workspacesByRepo[workspace.repositoryId] = list
    }

    func saveSettings(_ s: AppSettings) throws {
        try SettingsStore.save(s)
        settings = s
    }

    var globalSnapshot: GlobalSnapshot {
        GlobalSnapshot(
            repositories: repositories,
            workspacesByRepo: workspacesByRepo,
            settings: settings,
            repoMetadataByRepo: repoMetadataByRepo,
            prTrackerStatus: prTrackerStatus,
            rateLimits: rateLimits.windows
        )
    }

    /// Where uploaded files (pasted images, dropped files) land.
    static var uploadsDirectory: URL {
        Database.dataDirectory().appendingPathComponent("uploads", isDirectory: true)
    }

    /// Thread-safe counter for waiting on a batch of callbacks.
    final class Countdown: @unchecked Sendable {
        private let lock = NSLock()
        private var n: Int
        init(_ n: Int) { self.n = n }
        var value: Int { lock.withLock { n } }
        func decrement() { lock.withLock { n -= 1 } }
    }

    static func expandTilde(_ path: String) -> String {
        if path == "~" { return Platform.homeDirectory.path }
        if path.hasPrefix("~/") {
            return Platform.homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}
