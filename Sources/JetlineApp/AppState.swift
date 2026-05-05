import Foundation
import SwiftUI
import AppKit

/// Root observable state. Owns repositories, workspaces, sessions, selection.
@MainActor
final class AppState: ObservableObject {
    @Published var repositories: [Repository] = []
    @Published var workspacesByRepo: [String: [Workspace]] = [:]
    @Published var selectedWorkspaceId: String?
    @Published var sessionsByWorkspace: [String: [PTYSession]] = [:]
    @Published var activeSessionByWorkspace: [String: String] = [:]
    @Published var settings: AppSettings = AppSettings()
    @Published var diffByWorkspace: [String: DiffSnapshot] = [:]
    @Published var prDiffByWorkspace: [String: DiffSnapshot] = [:]
    @Published var localDiffByWorkspace: [String: DiffSnapshot] = [:]
    /// Tracked separately from the diff snapshots because porcelain status
    /// also flags untracked files, which `git diff` ignores.
    @Published var hasUncommittedByWorkspace: [String: Bool] = [:]
    @Published var prByWorkspace: [String: PRSnapshot] = [:]
    /// Local ahead/behind state per workspace, refreshed by `PRTracker` on
    /// each poll. Drives availability of `Pull updates` and `Rebase`.
    @Published var branchPositionByWorkspace: [String: BranchPosition] = [:]
    /// Per-repo GitHub metadata (owner/name + allowed merge methods),
    /// resolved on the first PR poll and reused for the app's lifetime.
    /// Drives the merge confirmation dialog's button set.
    @Published var repoMetadataByRepo: [String: RepoIdentifier] = [:]
    /// Pure-git action currently in flight for a workspace (rebase, pull,
    /// merge). The toolbar reads this to swap the git action button for a
    /// spinner so the user knows something is happening between click and
    /// completion. Cleared when the operation finishes — successful pure-git
    /// runs return here; falls-back-to-agent runs clear too because the new
    /// session takes over the visual indication.
    @Published var runningGitActionByWorkspace: [String: GitAction] = [:]
    @Published var prTrackerStatus: PRTracker.Status = .ok
    @Published var inspectorVisible: Bool = true
    /// Active inspector tab. Lifted out of `InspectorView` so workspace
    /// creation can flip it to `.run` and surface live setup-script output.
    @Published var inspectorTab: InspectorTab = .changes
    /// Run-script controllers keyed by workspace id. `nil` means "never run".
    /// Kept around after exit so the user can review the last log.
    @Published var runByWorkspace: [String: RunController] = [:]
    /// Setup-script controllers keyed by workspace id. Created when a fresh
    /// workspace spins up; lingers after exit so the user can scroll back
    /// through the log until they trigger a real run.
    @Published var setupByWorkspace: [String: SetupController] = [:]

    private var watchers: [String: WorktreeWatcher] = [:]
    private(set) lazy var prTracker: PRTracker = PRTracker(state: self)
    private var hasLoaded = false

    init() {}

    // MARK: - Load

    /// Idempotent. Driven by `AppShell`'s `.task` so SwiftUI owns the
    /// lifecycle (instead of an init-time `Task { ... }` that escapes the
    /// SwiftUI graph and runs even when nothing observes the state).
    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        do {
            settings = try SettingsStore.load()
            let repos = try Repositories.all()
            repositories = repos
            for r in repos {
                workspacesByRepo[r.id] = (try? Workspaces.forRepository(r.id)) ?? []
            }
            // Hydrate PR snapshots from disk so the sidebar paints
            // stale-but-known state immediately. The tracker overwrites these
            // entries as fresh data lands.
            if let cached = try? PRSnapshots.loadAll() {
                prByWorkspace = cached
            }
        } catch {
            print("AppState load error: \(error)")
        }
        prTracker.sync()
    }

    // MARK: - Repositories

    /// Adds a repository and returns it so the caller can chain UI (e.g. open
    /// the settings sheet so the user configures scripts before the first
    /// workspace is spawned). Returns `nil` if the picker was dismissed or
    /// the path failed validation.
    @discardableResult
    func addRepository() async -> Repository? {
        guard let path = await pickDirectory() else { return nil }
        guard await WorktreeOps.isGitRepo(at: path) else {
            await presentError("Not a git repository: \(path)")
            return nil
        }
        do {
            let defaultBranch = (try? await WorktreeOps.defaultBranch(at: path)) ?? "main"
            let name = WorktreeOps.detectName(at: path)
            let repo = try Repositories.add(name: name, path: path, defaultBranch: defaultBranch)
            repositories.insert(repo, at: 0)
            workspacesByRepo[repo.id] = []
            prTracker.sync()
            return repo
        } catch {
            await presentError(error.localizedDescription)
            return nil
        }
    }

    func removeRepository(_ id: String) {
        if let workspaces = workspacesByRepo[id] {
            for ws in workspaces { detachWorkspace(ws.id) }
        }
        try? Repositories.remove(id: id)
        repositories.removeAll { $0.id == id }
        workspacesByRepo.removeValue(forKey: id)
        repoMetadataByRepo.removeValue(forKey: id)
        if selectedWorkspaceId.flatMap({ workspaceById($0) }) == nil {
            selectedWorkspaceId = nil
        }
        prTracker.sync()
    }

    func updateRepository(_ repo: Repository) {
        do {
            try Repositories.update(repo)
            if let idx = repositories.firstIndex(where: { $0.id == repo.id }) {
                repositories[idx] = repo
            }
        } catch {
            Task { await presentError(error.localizedDescription) }
        }
    }

    // MARK: - Workspaces

    func createWorkspace(in repo: Repository, name: String) async {
        let id = UUID().uuidString
        let slug = WorktreeOps.slug(name)
        let prefix = await effectiveBranchPrefix(for: repo)
        let branch = "\(prefix)\(slug)-\(id.prefix(6))"
        let agent = settings.defaultAgent

        do {
            let path = try await WorktreeOps.create(
                repoPath: repo.path,
                worktreeId: id,
                repoId: repo.id,
                branchName: branch,
                baseBranch: repo.defaultBranch
            )
            let now = Date()
            let ws = Workspace(
                id: id,
                repositoryId: repo.id,
                name: name,
                branchName: branch,
                baseBranch: repo.defaultBranch,
                worktreePath: path,
                agent: agent,
                createdAt: now,
                lastActiveAt: now
            )
            try Workspaces.insert(ws)
            workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
            // Push the new branch into the tracker so the sidebar gets a
            // PR snapshot for it on the next sweep.
            prTracker.kick(repoId: repo.id)
            selectWorkspace(ws.id)
            startSetupIfNeeded(workspace: ws, repository: repo)
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    /// Spin up a workspace against an existing PR's head branch. Picker
    /// already filters forks; if a fork slips through, the underlying
    /// `git fetch` will fail with a clear message.
    func createWorkspaceFromPR(
        in repo: Repository,
        pr: PRSummary,
        name: String
    ) async {
        await importBranchAsWorkspace(
            in: repo,
            branchName: pr.headRefName,
            baseBranch: pr.baseRefName,
            name: name
        )
    }

    /// Spin up a workspace against an existing remote branch. `remoteRef` is
    /// what `git for-each-ref` emits — e.g. `origin/feature`. The remote
    /// prefix is stripped to derive the local branch name.
    func createWorkspaceFromBranch(
        in repo: Repository,
        remoteRef: String,
        name: String
    ) async {
        await importBranchAsWorkspace(
            in: repo,
            branchName: repo.localName(forRemoteRef: remoteRef),
            baseBranch: repo.defaultBranch,
            name: name
        )
    }

    /// Shared body for the two import entry points. Branch identity is
    /// preserved verbatim — none of `effectiveBranchPrefix` / slug / id-suffix
    /// applies here.
    private func importBranchAsWorkspace(
        in repo: Repository,
        branchName: String,
        baseBranch: String,
        name: String
    ) async {
        let id = UUID().uuidString
        let agent = settings.defaultAgent
        let path: String
        do {
            path = try await WorktreeOps.importExisting(
                repoPath: repo.path,
                worktreeId: id,
                repoId: repo.id,
                branchName: branchName,
                remote: repo.remoteOrigin
            )
        } catch {
            await presentError(error.localizedDescription)
            return
        }

        let now = Date()
        let ws = Workspace(
            id: id,
            repositoryId: repo.id,
            name: name,
            branchName: branchName,
            baseBranch: baseBranch,
            worktreePath: path,
            agent: agent,
            createdAt: now,
            lastActiveAt: now
        )
        do {
            try Workspaces.insert(ws)
        } catch {
            // Worktree was created; the DB insert is the only thing that
            // failed. Tear the worktree down again so we don't leak it.
            // Pass `branchName: nil` — the local branch is the user's, not
            // ours, and they may want it for a retry.
            try? await WorktreeOps.remove(
                repoPath: repo.path,
                worktreePath: path,
                branchName: nil,
                force: true
            )
            await presentError(error.localizedDescription)
            return
        }
        workspacesByRepo[repo.id, default: []].insert(ws, at: 0)
        prTracker.kick(repoId: repo.id)
        selectWorkspace(ws.id)
        startSetupIfNeeded(workspace: ws, repository: repo)
    }

    /// Spawn the repo's setup script for `workspace` and route its output
    /// into the inspector's run panel. No-ops for blank scripts. The
    /// inspector flips to `.run` so the user lands on live output instead of
    /// the diff (which is empty for a brand-new worktree anyway).
    private func startSetupIfNeeded(workspace: Workspace, repository: Repository) {
        guard let script = repository.trimmedSetupScript else { return }
        let controller = SetupController(workspaceId: workspace.id)
        setupByWorkspace[workspace.id] = controller
        controller.start(
            script: script,
            cwd: workspace.worktreePath,
            env: ScriptRunner.defaultEnv(repoPath: repository.path)
        )
        inspectorTab = .run
        inspectorVisible = true
    }

    func setupController(for workspaceId: String) -> SetupController? {
        setupByWorkspace[workspaceId]
    }

    func archiveWorkspace(_ workspace: Workspace, removeWorktree: Bool) async {
        // Stop the run script first; otherwise it keeps writing to a deleted dir.
        runByWorkspace[workspace.id]?.discard()
        runByWorkspace.removeValue(forKey: workspace.id)
        detachWorkspace(workspace.id)

        let repo = repositories.first(where: { $0.id == workspace.repositoryId })
        if removeWorktree, let repo {
            if let archive = repo.trimmedArchiveScript {
                _ = await ScriptRunner.run(
                    archive,
                    cwd: workspace.worktreePath,
                    env: ScriptRunner.defaultEnv(repoPath: repo.path)
                )
            }
            try? await WorktreeOps.remove(
                repoPath: repo.path,
                worktreePath: workspace.worktreePath,
                branchName: workspace.branchName,
                force: true
            )
        }
        try? Workspaces.archive(id: workspace.id)
        try? PRSnapshots.remove(workspaceId: workspace.id)
        workspacesByRepo[workspace.repositoryId]?.removeAll { $0.id == workspace.id }
        if selectedWorkspaceId == workspace.id { selectedWorkspaceId = nil }
    }

    /// Compute the prefix prepended to a fresh workspace's branch name.
    ///
    /// The `branchPrefixMode` field is the source of truth when set:
    /// `.username` derives from `git config user.name`, `.custom` uses the
    /// stored `branchPrefix`, `.none` produces an empty string. Repos
    /// migrated from before the mode field have nil mode, in which case we
    /// honour the legacy fallback chain (custom value → global → built-in).
    private func effectiveBranchPrefix(for repo: Repository) async -> String {
        if let raw = repo.branchPrefixMode, let mode = BranchPrefixMode(rawValue: raw) {
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
        return repo.branchPrefix?.nonBlank
            ?? settings.globalBranchPrefix.nonBlank
            ?? "jetline/"
    }

    func selectWorkspace(_ id: String) {
        selectedWorkspaceId = id
        try? Workspaces.touch(id: id)

        guard let ws = workspaceById(id) else { return }
        ensureSessionExists(for: ws)
        startWatcher(for: ws)
        Task { await refreshDiff(for: ws) }
    }

    // MARK: - Sessions

    /// Repopulate tabs the first time a workspace is selected this app run.
    /// If the DB has open sessions, recreate them in resume mode so each
    /// agent reloads its conversation; otherwise start one fresh.
    private func ensureSessionExists(for workspace: Workspace) {
        guard sessionsByWorkspace[workspace.id]?.isEmpty ?? true else { return }

        let persisted = (try? Sessions.openForWorkspace(workspace.id)) ?? []
        // Only Claude tabs come back across launches; close the rest so they
        // don't accumulate as zombie open rows.
        for row in persisted where row.agent != .claude {
            try? Sessions.end(id: row.id)
        }
        // A Claude row is only resumable if its conversation file is on disk.
        // Claude doesn't write the JSONL until the first turn, so a tab the
        // user opened and never typed in leaves a row with no conversation —
        // `claude --resume <id>` would just error with "couldn't find
        // conversation" and re-spawn that broken state forever. End those
        // rows here so the workspace gets a fresh tab instead.
        let resumable = persisted.filter { row in
            guard row.agent == .claude else { return false }
            if Self.claudeConversationExists(cwd: workspace.worktreePath, sessionId: row.id) {
                return true
            }
            try? Sessions.end(id: row.id)
            return false
        }

        guard !resumable.isEmpty else {
            startNewSession(for: workspace, agent: workspace.agent)
            return
        }

        let hydrated = resumable.map { row in
            let session = PTYSession(
                id: row.id,
                workspaceId: workspace.id,
                agent: row.agent,
                cwd: workspace.worktreePath,
                isResume: true
            )
            attachExitHandler(to: session)
            return session
        }
        for session in hydrated {
            Task { await session.startIfNeeded() }
        }
        sessionsByWorkspace[workspace.id] = hydrated
        activeSessionByWorkspace[workspace.id] = hydrated.last?.id
    }

    /// Claude Code stores each conversation as
    /// `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, where
    /// `<encoded-cwd>` replaces every non-alphanumeric character with `-`.
    /// That means `/Users/x/.jetline/...` becomes `-Users-x--jetline-...`
    /// (the `/.` collapses to `--`), so a naïve `/`-only swap misses the
    /// dot and looks at a path that never exists — which would mark every
    /// Jetline-spawned Claude row ended on the next launch and break
    /// resume entirely.
    private static func claudeConversationExists(cwd: String, sessionId: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encoded = String(cwd.map { ch in
            ch.isLetter || ch.isNumber || ch == "-" ? ch : "-"
        })
        let path = "\(home)/.claude/projects/\(encoded)/\(sessionId).jsonl"
        return FileManager.default.fileExists(atPath: path)
    }

    func startNewSession(for workspace: Workspace, agent: Workspace.AgentKind) {
        let session = PTYSession(
            workspaceId: workspace.id,
            agent: agent,
            cwd: workspace.worktreePath
        )
        attachExitHandler(to: session)
        sessionsByWorkspace[workspace.id, default: []].append(session)
        activeSessionByWorkspace[workspace.id] = session.id

        let dbSession = Session(
            id: session.id,
            workspaceId: workspace.id,
            title: "\(agent.displayName) session",
            agent: agent,
            startedAt: Date()
        )
        try? Sessions.insert(dbSession)

        Task { await session.startIfNeeded() }
    }

    /// Mark the persisted session row ended when the PTY exits, regardless
    /// of cause. Without this a `--resume` that fails (Claude can't find
    /// the conversation, broken binary, etc.) leaves the row open and the
    /// next launch reattempts the same broken resume forever.
    private func attachExitHandler(to session: PTYSession) {
        let id = session.id
        session.onExit = {
            Task { @MainActor in try? Sessions.end(id: id) }
        }
    }

    func selectSession(_ sessionId: String, in workspaceId: String) {
        activeSessionByWorkspace[workspaceId] = sessionId
    }

    // MARK: - Git actions

    /// Spawns a fresh tab with the user-selected agent and the rendered
    /// prompt as its first message. Merge has its own path (`performMerge`)
    /// because the caller picks a strategy from the confirmation dialog.
    func startGitActionSession(for workspace: Workspace, action: GitAction) {
        let agent = resolveAgent(for: action)
        let repo = repositories.first(where: { $0.id == workspace.repositoryId })
        guard let template = GitActionPrompts.template(
            for: action,
            repository: repo,
            settings: settings
        ) else { return }

        let pr: PullRequest?
        let checks: [CheckRun]
        if case let .loaded(pull, runs) = prByWorkspace[workspace.id] {
            pr = pull
            checks = runs
        } else {
            pr = nil
            checks = []
        }
        let prompt = GitActionPrompts.render(template, workspace: workspace, pr: pr, checks: checks)

        let session = PTYSession(
            workspaceId: workspace.id,
            agent: agent,
            cwd: workspace.worktreePath,
            initialPrompt: prompt
        )
        attachExitHandler(to: session)
        sessionsByWorkspace[workspace.id, default: []].append(session)
        activeSessionByWorkspace[workspace.id] = session.id

        let dbSession = Session(
            id: session.id,
            workspaceId: workspace.id,
            title: "\(action.displayName) (\(agent.displayName))",
            agent: agent,
            startedAt: Date()
        )
        try? Sessions.insert(dbSession)
        Task { await session.startIfNeeded() }
    }

    /// Resolve the agent for a given action through the fallback chain:
    /// review → reviewAgent → defaultAgent; everything else → gitAgent →
    /// defaultAgent. `.shell` is filtered out because it can't act on a
    /// prompt autonomously.
    private func resolveAgent(for action: GitAction) -> Workspace.AgentKind {
        let preferred: Workspace.AgentKind? =
            action.usesReviewAgent ? settings.reviewAgent : settings.gitAgent
        let chosen = preferred ?? settings.defaultAgent
        return chosen == .shell ? .claude : chosen
    }

    /// Run `gh pr merge` with the user-picked strategy (no agent involved).
    /// On success persists the method as the repo's `lastMergeMethod` so
    /// next time it becomes the dialog's default. Kicks the PR tracker so
    /// the sidebar reflects the merged state without waiting for the next
    /// scheduled poll.
    func performMerge(for workspace: Workspace, method: MergeMethod) async {
        guard case let .loaded(pr, _) = prByWorkspace[workspace.id] else { return }
        runningGitActionByWorkspace[workspace.id] = .mergePR
        defer { runningGitActionByWorkspace.removeValue(forKey: workspace.id) }
        do {
            try await GitHubRunner.mergePR(pr.number, method: method, cwd: workspace.worktreePath)
        } catch {
            await presentError(error.localizedDescription)
            return
        }
        if var repo = repositories.first(where: { $0.id == workspace.repositoryId }),
           repo.lastMergeMethod != method.rawValue {
            repo.lastMergeMethod = method.rawValue
            updateRepository(repo)
        }
        prTracker.kick(workspaceId: workspace.id)
    }

    /// Fast path for `Rebase`. Tries `git fetch` + `git rebase --autostash`
    /// directly so the common no-conflict case completes without spending
    /// agent tokens; `--autostash` lets a dirty working tree go through
    /// untouched. Anything that goes wrong — conflicts, missing refs,
    /// fetch failure — aborts the partial rebase and hands off to the
    /// agent flow that already knows how to recover.
    func performRebase(for workspace: Workspace) async {
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }) else {
            startGitActionSession(for: workspace, action: .rebaseOnMain)
            return
        }
        runningGitActionByWorkspace[workspace.id] = .rebaseOnMain
        defer { runningGitActionByWorkspace.removeValue(forKey: workspace.id) }

        let cwd = workspace.worktreePath
        let baseRef = "\(repo.remoteOrigin)/\(repo.localName(forRemoteRef: workspace.baseBranch))"

        let fellBack: Bool
        do {
            await BranchPositionOps.fetch(repoPath: cwd, remote: repo.remoteOrigin)
            let result = try await GitRunner.run(["rebase", "--autostash", baseRef], cwd: cwd)
            fellBack = !result.success
        } catch {
            fellBack = true
        }

        if fellBack {
            _ = try? await GitRunner.run(["rebase", "--abort"], cwd: cwd)
            startGitActionSession(for: workspace, action: .rebaseOnMain)
            return
        }

        prTracker.kick(workspaceId: workspace.id)
        await refreshDiff(for: workspace)
    }

    /// Fast path for `Pull updates`. Mirrors `performRebase`: tries
    /// `git pull --rebase --autostash` directly and falls back to the agent
    /// flow on conflict / failure. Pull-rebase leaves a partial state in
    /// `.git/rebase-merge` on conflict; `git rebase --abort` clears it.
    func performPull(for workspace: Workspace) async {
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }) else {
            startGitActionSession(for: workspace, action: .pullUpdates)
            return
        }
        runningGitActionByWorkspace[workspace.id] = .pullUpdates
        defer { runningGitActionByWorkspace.removeValue(forKey: workspace.id) }

        let cwd = workspace.worktreePath

        let fellBack: Bool
        do {
            let result = try await GitRunner.run(
                ["pull", "--rebase", "--autostash", repo.remoteOrigin, workspace.branchName],
                cwd: cwd
            )
            fellBack = !result.success
        } catch {
            fellBack = true
        }

        if fellBack {
            _ = try? await GitRunner.run(["rebase", "--abort"], cwd: cwd)
            startGitActionSession(for: workspace, action: .pullUpdates)
            return
        }

        prTracker.kick(workspaceId: workspace.id)
        await refreshDiff(for: workspace)
    }

    /// Last merge method the user chose for this workspace's repo. `nil`
    /// when the user has never merged here.
    func lastMergeMethod(for workspace: Workspace) -> MergeMethod? {
        repositories
            .first(where: { $0.id == workspace.repositoryId })?
            .lastMergeMethod
            .flatMap(MergeMethod.init(rawValue:))
    }

    func activeSession(for workspaceId: String) -> PTYSession? {
        guard let id = activeSessionByWorkspace[workspaceId] else { return nil }
        return sessionsByWorkspace[workspaceId]?.first { $0.id == id }
    }

    /// Close one tab. Picks a neighbour to activate; if it was the last tab,
    /// spawns a fresh one with the default agent so the workspace is never
    /// empty (the surface would otherwise show only a spinner).
    func closeSession(_ sessionId: String, in workspaceId: String) {
        guard var sessions = sessionsByWorkspace[workspaceId],
              let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = sessions.remove(at: idx)
        session.terminate()
        try? Sessions.end(id: sessionId)
        sessionsByWorkspace[workspaceId] = sessions

        if activeSessionByWorkspace[workspaceId] == sessionId {
            let neighbour = idx < sessions.count ? sessions[idx] : sessions.last
            activeSessionByWorkspace[workspaceId] = neighbour?.id
        }

        if sessions.isEmpty, let ws = workspaceById(workspaceId) {
            startNewSession(for: ws, agent: settings.defaultAgent)
        }
    }

    /// Activate the Nth tab (1-indexed) of the active workspace. Used by ⌘1…⌘9.
    func selectSessionByIndex(_ oneBased: Int) {
        guard let wsId = selectedWorkspaceId,
              let sessions = sessionsByWorkspace[wsId],
              oneBased >= 1, oneBased <= sessions.count else { return }
        selectSession(sessions[oneBased - 1].id, in: wsId)
    }

    // MARK: - Run script

    /// Toggle the run script for a workspace. Honours the per-repo
    /// `runExclusive` flag — starting an exclusive run stops every other
    /// active runner in the same repository first.
    func toggleRun(for workspace: Workspace) {
        if let runner = runByWorkspace[workspace.id], runner.isRunning {
            runner.stop()
            return
        }
        guard let repo = repositories.first(where: { $0.id == workspace.repositoryId }),
              let script = repo.trimmedRunScript else { return }

        if repo.runExclusive {
            let peerIds = Set(workspacesByRepo[repo.id]?.map(\.id) ?? [])
            for (otherId, runner) in runByWorkspace
            where otherId != workspace.id && peerIds.contains(otherId) && runner.isRunning {
                runner.stop()
            }
        }

        // Drop the setup transcript so that when the run eventually exits
        // the panel falls back to the placeholder, not to "Setup complete".
        if let setup = setupByWorkspace.removeValue(forKey: workspace.id) {
            setup.discard()
        }

        let runner = runByWorkspace[workspace.id] ?? RunController(workspaceId: workspace.id)
        runByWorkspace[workspace.id] = runner
        runner.start(
            script: script,
            cwd: workspace.worktreePath,
            env: ScriptRunner.defaultEnv(repoPath: repo.path)
        )
    }

    func runController(for workspaceId: String) -> RunController? {
        runByWorkspace[workspaceId]
    }

    func isRunActive(_ workspaceId: String) -> Bool {
        runByWorkspace[workspaceId]?.isRunning ?? false
    }

    func hasRunHistory(_ workspaceId: String) -> Bool {
        runByWorkspace[workspaceId] != nil
    }

    func hasRunScript(_ workspace: Workspace) -> Bool {
        repositories.first { $0.id == workspace.repositoryId }?.trimmedRunScript != nil
    }

    /// Cycle to the next or previous tab of the active workspace. Wraps.
    func cycleSession(forward: Bool) {
        guard let wsId = selectedWorkspaceId,
              let sessions = sessionsByWorkspace[wsId],
              !sessions.isEmpty,
              let activeId = activeSessionByWorkspace[wsId],
              let idx = sessions.firstIndex(where: { $0.id == activeId }) else { return }
        let next = (idx + (forward ? 1 : -1) + sessions.count) % sessions.count
        selectSession(sessions[next].id, in: wsId)
    }

    // MARK: - Diff & watcher

    func refreshDiff(for workspace: Workspace) async {
        async let combined: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .combined
            )
        }()
        async let prSnap: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .pr
            )
        }()
        async let localSnap: DiffSnapshot? = {
            try? await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: .local
            )
        }()
        async let uncommitted = DiffComputer.hasUncommittedChanges(
            worktreePath: workspace.worktreePath
        )

        if let snap = await combined, diffByWorkspace[workspace.id] != snap {
            diffByWorkspace[workspace.id] = snap
        }
        if let snap = await prSnap, prDiffByWorkspace[workspace.id] != snap {
            prDiffByWorkspace[workspace.id] = snap
        }
        if let snap = await localSnap, localDiffByWorkspace[workspace.id] != snap {
            localDiffByWorkspace[workspace.id] = snap
        }
        let dirty = await uncommitted
        if hasUncommittedByWorkspace[workspace.id] != dirty {
            hasUncommittedByWorkspace[workspace.id] = dirty
        }
    }

    /// Single write path for PR snapshots. `PRTracker` calls this with fresh
    /// data; the in-memory map drives the UI and the same value is mirrored
    /// to disk so the next launch can paint immediately. No-op writes are
    /// suppressed so we don't kick every observer on every poll.
    func applyPR(_ snapshot: PRSnapshot, for workspaceId: String) {
        if prByWorkspace[workspaceId] != snapshot {
            prByWorkspace[workspaceId] = snapshot
        }
        try? PRSnapshots.save(snapshot, for: workspaceId)
    }

    /// Single write path for the repo metadata cache. PRTracker calls this
    /// when it first resolves a repo's owner/name + allowed merge methods.
    /// No-op writes are suppressed so Combine doesn't notify on every poll.
    func applyRepoMetadata(_ metadata: RepoIdentifier, for repoId: String) {
        if repoMetadataByRepo[repoId] != metadata {
            repoMetadataByRepo[repoId] = metadata
        }
    }

    /// Single write path for branch positions. No-op writes are suppressed
    /// so an unchanged ahead/behind state doesn't kick every observer.
    func applyBranchPosition(_ position: BranchPosition, for workspaceId: String) {
        if branchPositionByWorkspace[workspaceId] != position {
            branchPositionByWorkspace[workspaceId] = position
        }
    }

    private func startWatcher(for workspace: Workspace) {
        guard watchers[workspace.id] == nil else { return }
        let id = workspace.id
        let worktreePath = workspace.worktreePath
        // Resolve the worktree's git-dir asynchronously so we can watch
        // both. Without watching the git-dir, `git commit` (which mutates
        // `<repo>/.git/worktrees/<id>/{HEAD,index}` outside the worktree
        // path) doesn't fire FSEvents and the diff snapshot stays stale.
        // selectWorkspace already kicks off a refreshDiff so the brief
        // window before the watcher arms is covered.
        Task { [weak self] in
            guard let self else { return }
            let gitDir = await WorktreeOps.gitDir(at: worktreePath)
            await MainActor.run {
                guard self.watchers[id] == nil,
                      self.workspaceById(id) != nil else { return }
                var paths = [worktreePath]
                if let gitDir, gitDir != worktreePath {
                    paths.append(gitDir)
                }
                let watcher = WorktreeWatcher(paths: paths) { [weak self] in
                    guard let self else { return }
                    guard let ws = self.workspaceById(id) else { return }
                    Task { await self.refreshDiff(for: ws) }
                    // Worktree changed — likely a commit or push. Wake the
                    // PR tracker so the sidebar reflects new state without
                    // waiting up to a minute for the next scheduled poll.
                    self.prTracker.kick(workspaceId: id)
                }
                watcher.start()
                self.watchers[id] = watcher
            }
        }
    }

    private func detachWorkspace(_ id: String) {
        watchers[id]?.stop()
        watchers.removeValue(forKey: id)
        for s in sessionsByWorkspace[id] ?? [] { s.terminate() }
        sessionsByWorkspace.removeValue(forKey: id)
        activeSessionByWorkspace.removeValue(forKey: id)
        diffByWorkspace.removeValue(forKey: id)
        prDiffByWorkspace.removeValue(forKey: id)
        localDiffByWorkspace.removeValue(forKey: id)
        hasUncommittedByWorkspace.removeValue(forKey: id)
        prByWorkspace.removeValue(forKey: id)
        branchPositionByWorkspace.removeValue(forKey: id)
        setupByWorkspace[id]?.discard()
        setupByWorkspace.removeValue(forKey: id)
    }

    // MARK: - Helpers

    func workspaceById(_ id: String) -> Workspace? {
        for list in workspacesByRepo.values {
            if let ws = list.first(where: { $0.id == id }) { return ws }
        }
        return nil
    }

    func saveSettings(_ s: AppSettings) {
        do {
            try SettingsStore.save(s)
            settings = s
        } catch {
            Task { await presentError(error.localizedDescription) }
        }
    }

    private func pickDirectory() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.title = "Add repository"
                panel.prompt = "Add"
                panel.begin { resp in
                    if resp == .OK, let url = panel.url {
                        continuation.resume(returning: url.path)
                    } else {
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    private func presentError(_ message: String) async {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
