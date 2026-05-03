import Foundation

/// Background tracker that keeps `AppState.prByWorkspace` populated for every
/// workspace in every repository. One poll loop per repo runs in parallel,
/// each issuing a single batched GraphQL call per cycle (one alias per
/// workspace branch).
///
/// Cadence per repo:
///   - 15s when any workspace in the repo has an in-flight check
///   - 60s otherwise
///   - exponential backoff (30s → 5min) while a repo's last poll errored
///
/// `kick(...)` cancels the current sleep so the next poll happens immediately
/// — used by `WorktreeWatcher` (post-push), `PRPanel` (panel opened), and the
/// "Refresh" button.
@MainActor
final class PRTracker {
    enum Status: Equatable {
        case ok
        case ghMissing
        case authRequired

        var userMessage: String? {
            switch self {
            case .ok:           return nil
            case .ghMissing:    return "gh CLI not found — install via `brew install gh`."
            case .authRequired: return "gh not authenticated — run `gh auth login` in a terminal."
            }
        }
    }

    private weak var state: AppState?

    /// Cached owner/name per repo. Outer optional = "lookup not yet attempted";
    /// inner `nil` = "looked up, repo has no GitHub remote — skip forever".
    private var repoIdentifiers: [String: RepoIdentifier?] = [:]
    private var repoTasks: [String: Task<Void, Never>] = [:]
    private var sleepTasks: [String: Task<Void, Never>] = [:]
    private var failureCount: [String: Int] = [:]
    /// Workspace IDs we've already kicked off auto-archive for. The archive
    /// itself removes the workspace from `workspacesByRepo`, so subsequent
    /// polls won't see it — but the archive is fire-and-forget, so this
    /// guard prevents a re-trigger before it lands.
    private var autoArchived: Set<String> = []

    init(state: AppState) {
        self.state = state
    }

    /// Reconcile poll loops with the current set of repositories. Idempotent
    /// — call after add/remove/load/archive.
    func sync() {
        guard let state else { return }
        let current = Set(state.repositories.map(\.id))
        for repoId in repoTasks.keys where !current.contains(repoId) {
            stop(repoId: repoId)
            repoIdentifiers.removeValue(forKey: repoId)
            failureCount.removeValue(forKey: repoId)
        }
        for repo in state.repositories where repoTasks[repo.id] == nil {
            startLoop(repoId: repo.id)
        }
    }

    func stopAll() {
        for (_, t) in repoTasks { t.cancel() }
        repoTasks.removeAll()
        for (_, t) in sleepTasks { t.cancel() }
        sleepTasks.removeAll()
    }

    /// Wake a repo's loop so the next poll happens immediately.
    func kick(repoId: String) {
        sleepTasks[repoId]?.cancel()
    }

    func kick(workspaceId: String) {
        guard let ws = state?.workspaceById(workspaceId) else { return }
        kick(repoId: ws.repositoryId)
    }

    // MARK: - Private

    private func stop(repoId: String) {
        repoTasks.removeValue(forKey: repoId)?.cancel()
        sleepTasks.removeValue(forKey: repoId)?.cancel()
    }

    private func startLoop(repoId: String) {
        let task = Task<Void, Never> { [weak self] in
            await self?.loop(repoId: repoId)
        }
        repoTasks[repoId] = task
    }

    private func loop(repoId: String) async {
        while !Task.isCancelled {
            await pollOnce(repoId: repoId)
            if Task.isCancelled { return }
            await sleepUntilNext(repoId: repoId)
        }
    }

    private func pollOnce(repoId: String) async {
        guard let state,
              let repo = state.repositories.first(where: { $0.id == repoId }) else { return }
        let workspaces = state.workspacesByRepo[repoId] ?? []
        guard !workspaces.isEmpty else {
            // No workspaces yet — nothing to fetch. Reset failure count so we
            // don't accumulate backoff while the user is still setting up.
            failureCount[repoId] = 0
            return
        }

        // Local ahead/behind: independent of GitHub, so it stays fresh even
        // for repos with no GitHub remote or while `gh` is broken.
        await refreshBranchPositions(repo: repo, workspaces: workspaces)

        let identifier: RepoIdentifier
        switch await resolvedIdentifier(for: repo) {
        case .resolved(let id): identifier = id
        case .notOnGitHub:      return
        case .deferred:         return  // error already recorded; backoff applies
        }

        do {
            let result = try await GitHubRunner.batchFetchPRs(
                repo: identifier,
                branches: workspaces.map(\.branchName),
                cwd: repo.path
            )
            failureCount[repoId] = 0
            updateStatus(.ok)
            for ws in workspaces {
                let snap: PRSnapshot
                if let (pr, checks) = result[ws.branchName] {
                    snap = .loaded(pr, checks)
                } else {
                    snap = .absent
                }
                state.applyPR(snap, for: ws.id)
                autoArchiveIfMerged(workspace: ws, snapshot: snap, state: state)
            }
        } catch GitHubRunner.Error.ghMissing {
            updateStatus(.ghMissing)
            failureCount[repoId, default: 0] += 1
        } catch GitHubRunner.Error.authRequired {
            updateStatus(.authRequired)
            failureCount[repoId, default: 0] += 1
        } catch {
            failureCount[repoId, default: 0] += 1
        }
    }

    /// One `git fetch` per repo (cheap when nothing changed remotely), then
    /// per-workspace ahead/behind comparison. Errors fall through silently
    /// — a stale count is better than blocking the loop on an offline fetch.
    private func refreshBranchPositions(repo: Repository, workspaces: [Workspace]) async {
        await BranchPositionOps.fetch(repoPath: repo.path, remote: repo.remoteOrigin)
        for ws in workspaces {
            let pos = await BranchPositionOps.compute(
                worktreePath: ws.worktreePath,
                branchName: ws.branchName,
                baseBranch: ws.baseBranch,
                remote: repo.remoteOrigin
            )
            state?.applyBranchPosition(pos, for: ws.id)
        }
    }

    private enum IdentifierResult {
        case resolved(RepoIdentifier)
        case notOnGitHub
        case deferred
    }

    private func resolvedIdentifier(for repo: Repository) async -> IdentifierResult {
        if let cached = repoIdentifiers[repo.id] {
            return cached.map(IdentifierResult.resolved) ?? .notOnGitHub
        }
        do {
            if let id = try await GitHubRunner.repoIdentifier(cwd: repo.path) {
                repoIdentifiers[repo.id] = .some(id)
                state?.applyRepoMetadata(id, for: repo.id)
                return .resolved(id)
            } else {
                repoIdentifiers[repo.id] = .some(nil)
                return .notOnGitHub
            }
        } catch GitHubRunner.Error.ghMissing {
            updateStatus(.ghMissing)
            failureCount[repo.id, default: 0] += 1
            return .deferred
        } catch GitHubRunner.Error.authRequired {
            updateStatus(.authRequired)
            failureCount[repo.id, default: 0] += 1
            return .deferred
        } catch {
            failureCount[repo.id, default: 0] += 1
            return .deferred
        }
    }

    private func sleepUntilNext(repoId: String) async {
        let interval = nextInterval(repoId: repoId)
        let task = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(interval))
        }
        sleepTasks[repoId] = task
        await task.value
        if sleepTasks[repoId] == task {
            sleepTasks.removeValue(forKey: repoId)
        }
    }

    /// 30s, 60s, 120s, 240s, capped at 300s while errored. Otherwise 15s
    /// when any workspace has an active check, 60s when quiescent.
    private func nextInterval(repoId: String) -> Double {
        let failures = failureCount[repoId] ?? 0
        if failures > 0 {
            return min(300, 30 * pow(2, Double(failures - 1)))
        }
        guard let state else { return 60 }
        let wsIds = (state.workspacesByRepo[repoId] ?? []).map(\.id)
        let anyActive = wsIds.contains { id in
            if case let .loaded(_, checks) = state.prByWorkspace[id] {
                return checks.contains(where: \.isActive)
            }
            return false
        }
        return anyActive ? 15 : 60
    }

    /// Worktree is preserved (`removeWorktree: false`) so the user keeps
    /// any uncommitted post-merge work; the row simply leaves the sidebar.
    private func autoArchiveIfMerged(workspace: Workspace, snapshot: PRSnapshot, state: AppState) {
        guard case let .loaded(pr, _) = snapshot,
              pr.state.uppercased() == "MERGED",
              !autoArchived.contains(workspace.id) else { return }
        autoArchived.insert(workspace.id)
        Task { await state.archiveWorkspace(workspace, removeWorktree: false) }
    }

    private func updateStatus(_ new: Status) {
        guard let state, state.prTrackerStatus != new else { return }
        state.prTrackerStatus = new
    }
}
