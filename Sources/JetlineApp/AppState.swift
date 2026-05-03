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
    /// Per-repo GitHub metadata (owner/name + allowed merge methods),
    /// resolved on the first PR poll and reused for the app's lifetime.
    /// Drives the merge confirmation dialog's button set.
    @Published var repoMetadataByRepo: [String: RepoIdentifier] = [:]
    @Published var prTrackerStatus: PRTracker.Status = .ok
    @Published var inspectorVisible: Bool = true
    /// Run-script controllers keyed by workspace id. `nil` means "never run".
    /// Kept around after exit so the user can review the last log.
    @Published var runByWorkspace: [String: RunController] = [:]

    private var watchers: [String: WorktreeWatcher] = [:]
    private(set) lazy var prTracker: PRTracker = PRTracker(state: self)

    init() {
        Task { await load() }
    }

    // MARK: - Load

    func load() async {
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

    func addRepository() async {
        guard let path = await pickDirectory() else { return }
        guard await WorktreeOps.isGitRepo(at: path) else {
            await presentError("Not a git repository: \(path)")
            return
        }
        do {
            let defaultBranch = (try? await WorktreeOps.defaultBranch(at: path)) ?? "main"
            let name = WorktreeOps.detectName(at: path)
            let repo = try Repositories.add(name: name, path: path, defaultBranch: defaultBranch)
            repositories.insert(repo, at: 0)
            workspacesByRepo[repo.id] = []
            prTracker.sync()
        } catch {
            await presentError(error.localizedDescription)
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

    func createWorkspace(in repo: Repository, name: String, agent: Workspace.AgentKind) async {
        let id = UUID().uuidString
        let slug = WorktreeOps.slug(name)
        let prefix = effectiveBranchPrefix(for: repo)
        let branch = "\(prefix)\(slug)-\(id.prefix(6))"

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

            if let setup = repo.trimmedSetupScript {
                if let result = await ScriptRunner.run(
                    setup,
                    cwd: path,
                    env: ScriptRunner.defaultEnv(repoPath: repo.path)
                ), !result.success {
                    await presentError(
                        "Setup script failed (\(result.status)).\n\n\(result.stderr.isEmpty ? result.stdout : result.stderr)"
                    )
                }
            }
        } catch {
            await presentError(error.localizedDescription)
        }
    }

    func archiveWorkspace(_ workspace: Workspace, removeWorktree: Bool) async {
        // Stop the run script first; otherwise it keeps writing to a deleted dir.
        runByWorkspace[workspace.id]?.stop()
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

    private func effectiveBranchPrefix(for repo: Repository) -> String {
        repo.branchPrefix?.nonBlank
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
        let resumable = persisted.filter { $0.agent == .claude }

        guard !resumable.isEmpty else {
            startNewSession(for: workspace, agent: workspace.agent)
            return
        }

        let hydrated = resumable.map { row in
            PTYSession(
                id: row.id,
                workspaceId: workspace.id,
                agent: row.agent,
                cwd: workspace.worktreePath,
                isResume: true
            )
        }
        for session in hydrated {
            Task { await session.startIfNeeded() }
        }
        sessionsByWorkspace[workspace.id] = hydrated
        activeSessionByWorkspace[workspace.id] = hydrated.last?.id
    }

    func startNewSession(for workspace: Workspace, agent: Workspace.AgentKind) {
        let session = PTYSession(
            workspaceId: workspace.id,
            agent: agent,
            cwd: workspace.worktreePath
        )
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

        let runner = runByWorkspace[workspace.id] ?? RunController(
            workspaceId: workspace.id,
            onExit: { _ in }
        )
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

    private func startWatcher(for workspace: Workspace) {
        guard watchers[workspace.id] == nil else { return }
        let id = workspace.id
        let watcher = WorktreeWatcher(path: workspace.worktreePath) { [weak self] in
            guard let self else { return }
            guard let ws = self.workspaceById(id) else { return }
            Task { await self.refreshDiff(for: ws) }
            // Worktree changed — likely a commit or push. Wake the PR
            // tracker so the sidebar reflects new state without waiting up
            // to a minute for the next scheduled poll.
            self.prTracker.kick(workspaceId: id)
        }
        watcher.start()
        watchers[workspace.id] = watcher
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
