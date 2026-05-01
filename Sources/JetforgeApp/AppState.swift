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
    @Published var inspectorVisible: Bool = true
    /// Run-script controllers keyed by workspace id. `nil` means "never run".
    /// Kept around after exit so the user can review the last log.
    @Published var runByWorkspace: [String: RunController] = [:]

    private var watchers: [String: WorktreeWatcher] = [:]

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
        } catch {
            print("AppState load error: \(error)")
        }
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
        if selectedWorkspaceId.flatMap({ workspaceById($0) }) == nil {
            selectedWorkspaceId = nil
        }
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
        workspacesByRepo[workspace.repositoryId]?.removeAll { $0.id == workspace.id }
        if selectedWorkspaceId == workspace.id { selectedWorkspaceId = nil }
    }

    private func effectiveBranchPrefix(for repo: Repository) -> String {
        repo.branchPrefix?.nonBlank
            ?? settings.globalBranchPrefix.nonBlank
            ?? "jetforge/"
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

    private func ensureSessionExists(for workspace: Workspace) {
        if (sessionsByWorkspace[workspace.id]?.isEmpty ?? true) {
            startNewSession(for: workspace, agent: workspace.agent)
        }
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
        do {
            let snapshot = try await DiffComputer.compute(
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch
            )
            diffByWorkspace[workspace.id] = snapshot
        } catch {
            diffByWorkspace[workspace.id] = .empty
        }
    }

    private func startWatcher(for workspace: Workspace) {
        guard watchers[workspace.id] == nil else { return }
        let id = workspace.id
        let watcher = WorktreeWatcher(path: workspace.worktreePath) { [weak self] in
            guard let self else { return }
            guard let ws = self.workspaceById(id) else { return }
            Task { await self.refreshDiff(for: ws) }
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
