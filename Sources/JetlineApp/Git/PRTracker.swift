import Foundation

/// Background tracker that keeps each workspace's `WorkspaceState.pr`
/// populated for every workspace in every repository. Two loops per repo
/// run in parallel,
/// decoupled because they have very different cost profiles:
///
///   - **Local loop** (`pollLocal`): `git fetch`, fast-forward the local
///     default branch, recompute per-workspace ahead/behind. Free re:
///     GitHub API — just bandwidth — so we run it aggressively.
///       * 20s, always.
///   - **GitHub loop** (`pollGitHub`): one batched `gh api graphql` per
///     repo (one alias per workspace branch). Each query consumes 5–15
///     points per branch against the 5000-points/hour budget, so this
///     loop runs slower and tunes itself based on activity.
///       * 15s when any workspace in the repo has an in-flight check
///       * 60s otherwise
///       * exponential backoff (30s → 5min) while a repo's last poll errored
///
/// `kick(...)` cancels both sleeps so the next poll of either loop
/// happens immediately — used by `WorktreeWatcher` (post-push), `PRPanel`
/// (panel opened), the workspace creation sheet, and the "Refresh" button.
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

    /// Per-repo tracker state. One entry per active repository; created
    /// in `startLoops`, torn down in `stop`.
    private struct Loops {
        var local: Task<Void, Never>?
        var github: Task<Void, Never>?
        var localSleep: Task<Void, Never>?
        var githubSleep: Task<Void, Never>?
        /// Set by `kick` when the corresponding sleep is `nil` (i.e. the
        /// loop is mid-poll and there's nothing to cancel). Consumed in
        /// `runLoop` between poll and sleep so a kick that lands during a
        /// poll re-triggers immediately instead of being silently dropped.
        var localKickPending: Bool = false
        var githubKickPending: Bool = false
        /// GitHub-only — local fetch failures don't bill against the
        /// GitHub rate limit and shouldn't slow the whole tracker down.
        var githubFailures: Int = 0

        mutating func cancelAll() {
            local?.cancel(); local = nil
            github?.cancel(); github = nil
            localSleep?.cancel(); localSleep = nil
            githubSleep?.cancel(); githubSleep = nil
        }
    }

    /// Pair of keypaths identifying which sleep slot and pending-kick flag
    /// a poll loop owns. Lets `kick`, `runLoop`, and `startLoops` parameterize
    /// over local-vs-github without restating the field names.
    private struct LoopBinding: Sendable {
        let sleep: WritableKeyPath<Loops, Task<Void, Never>?> & Sendable
        let kickPending: WritableKeyPath<Loops, Bool> & Sendable

        static let local = LoopBinding(sleep: \.localSleep, kickPending: \.localKickPending)
        static let github = LoopBinding(sleep: \.githubSleep, kickPending: \.githubKickPending)
    }

    private weak var state: AppState?

    /// Cached owner/name per repo. Outer optional = "lookup not yet attempted";
    /// inner `nil` = "looked up, repo has no GitHub remote — skip forever".
    private var repoIdentifiers: [String: RepoIdentifier?] = [:]
    private var loops: [String: Loops] = [:]
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
        for repoId in loops.keys where !current.contains(repoId) {
            stop(repoId: repoId)
            repoIdentifiers.removeValue(forKey: repoId)
        }
        for repo in state.repositories where loops[repo.id] == nil {
            startLoops(repoId: repo.id)
        }
    }

    func stopAll() {
        for repoId in loops.keys { stop(repoId: repoId) }
        repoIdentifiers.removeAll()
        autoArchived.removeAll()
    }

    /// Wake both loops so the next poll of each fires immediately. If a
    /// loop is currently mid-poll its sleep is `nil`, so the cancel has
    /// nothing to land on — the pending flag carries the kick across into
    /// `runLoop`'s post-poll check.
    func kick(repoId: String) {
        cancelOrPend(repoId: repoId, binding: .local)
        cancelOrPend(repoId: repoId, binding: .github)
    }

    private func cancelOrPend(repoId: String, binding: LoopBinding) {
        if let sleep = loops[repoId]?[keyPath: binding.sleep] {
            sleep.cancel()
        } else {
            loops[repoId]?[keyPath: binding.kickPending] = true
        }
    }

    func kick(workspaceId: String) {
        guard let ws = state?.workspaceById(workspaceId) else { return }
        kick(repoId: ws.repositoryId)
    }

    // MARK: - Lifecycle

    private func stop(repoId: String) {
        loops[repoId]?.cancelAll()
        loops.removeValue(forKey: repoId)
    }

    private func startLoops(repoId: String) {
        var entry = Loops()
        entry.local = Task<Void, Never> { [weak self] in
            await self?.runLoop(
                repoId: repoId,
                minInterval: 5,
                interval: { _ in 20 },
                binding: .local,
                poll: { await $0.pollLocal(repoId: repoId) }
            )
        }
        entry.github = Task<Void, Never> { [weak self] in
            await self?.runLoop(
                repoId: repoId,
                minInterval: 15,
                interval: { $0.nextGitHubInterval(repoId: repoId) },
                binding: .github,
                poll: { await $0.pollGitHub(repoId: repoId) }
            )
        }
        loops[repoId] = entry
    }

    /// Drive a per-repo poll loop until cancelled. The caller owns the
    /// poll body and the interval policy; this just sequences poll →
    /// sleep → poll and keeps the sleep `Task` reachable so `kick(...)`
    /// can cancel it. The cancellation handler propagates parent
    /// cancellation into the inner sleep — without it, stopping the
    /// loop would block until the current sleep finished naturally.
    ///
    /// `minInterval` is the absolute floor between successive polls,
    /// enforced even when a kick lands. Without it, a sustained burst
    /// of kicks (FSEvents-driven, e.g. an active dev server writing into
    /// a worktree) chains `kickPending` from poll to poll and the loop
    /// tight-spins at ~1 poll/sec — fine for `git fetch`, fatal for the
    /// GitHub query budget.
    private func runLoop(
        repoId: String,
        minInterval: Double,
        interval: @escaping (PRTracker) -> Double,
        binding: LoopBinding,
        poll: @escaping (PRTracker) async -> Void
    ) async {
        var lastPollStart: Date = .distantPast
        while !Task.isCancelled {
            // Floor: never start a poll faster than `minInterval` after the
            // previous one started, regardless of pending kicks. The floor
            // sleep is uninterruptible (cancel-only) so a user-initiated
            // kick waits up to `minInterval` for the next poll.
            let elapsed = Date().timeIntervalSince(lastPollStart)
            if elapsed < minInterval {
                try? await Task.sleep(for: .seconds(minInterval - elapsed))
                if Task.isCancelled { return }
            }
            lastPollStart = Date()
            await poll(self)
            if Task.isCancelled { return }
            // Honor a kick that landed while the poll was running (sleep
            // was `nil`, so the cancel had nowhere to go). Skip the
            // upcoming sleep — the floor at top of loop still applies.
            if loops[repoId]?[keyPath: binding.kickPending] == true {
                loops[repoId]?[keyPath: binding.kickPending] = false
                continue
            }
            let sleep = Task<Void, Never> {
                try? await Task.sleep(for: .seconds(interval(self)))
            }
            loops[repoId]?[keyPath: binding.sleep] = sleep
            await withTaskCancellationHandler {
                await sleep.value
            } onCancel: {
                sleep.cancel()
            }
            if loops[repoId]?[keyPath: binding.sleep] == sleep {
                loops[repoId]?[keyPath: binding.sleep] = nil
            }
        }
    }

    // MARK: - Local refs loop

    private func pollLocal(repoId: String) async {
        guard let state,
              let repo = state.repositories.first(where: { $0.id == repoId }) else { return }
        let workspaces = state.workspacesByRepo[repoId] ?? []

        // Refresh refs first — must run even when the repo has no
        // workspaces yet so the local default branch stays current and
        // any worktree the user creates next inherits a fresh tip.
        await BranchPositionOps.fetch(repoPath: repo.path, remote: repo.remoteOrigin)
        state.activityLog.record(
            .fetch,
            "Fetched refs from \(repo.remoteOrigin)",
            repoId: repoId
        )
        let newBaseSHA = await BaseBranchSync.fastForward(
            repoPath: repo.path,
            remote: repo.remoteOrigin,
            baseBranch: repo.defaultBranch
        )
        if let newBaseSHA {
            state.activityLog.record(
                .fastForward,
                "Fast-forwarded \(repo.defaultBranch) → \(newBaseSHA.prefix(7))",
                repoId: repoId
            )
            // Merge-base shifted under every workspace's diff — recompute
            // so the inspector reflects reality. No-op when no diff is
            // open; refreshDiff is deduped on equality. Left sequential
            // because the baseMoved branch is rare and each refreshDiff
            // already fans out internally.
            for ws in workspaces {
                await state.refreshDiff(for: ws)
            }
        }

        // Compute every workspace's branch position concurrently. The
        // computes themselves are read-only; we apply the results back on
        // main once they all land. Without this, N workspaces × 4
        // sequential subprocesses each meant ~10× more wall time per
        // poll than the slowest single workspace.
        let remote = repo.remoteOrigin
        let positions: [(String, BranchPosition)] = await withTaskGroup(
            of: (String, BranchPosition).self
        ) { group in
            for ws in workspaces {
                let id = ws.id
                let worktreePath = ws.worktreePath
                let branchName = ws.branchName
                let baseBranch = ws.baseBranch
                group.addTask {
                    let pos = await BranchPositionOps.compute(
                        worktreePath: worktreePath,
                        branchName: branchName,
                        baseBranch: baseBranch,
                        remote: remote
                    )
                    return (id, pos)
                }
            }
            var collected: [(String, BranchPosition)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        for (id, pos) in positions {
            state.applyBranchPosition(pos, for: id)
        }
    }

    // MARK: - GitHub loop

    private func pollGitHub(repoId: String) async {
        guard let state,
              let repo = state.repositories.first(where: { $0.id == repoId }) else { return }
        let workspaces = state.workspacesByRepo[repoId] ?? []
        guard !workspaces.isEmpty else {
            loops[repoId]?.githubFailures = 0
            return
        }

        // Clear any refresh-in-flight markers regardless of outcome — the
        // poll has reached terminal state, so the spinner should stop
        // whether or not the snapshot actually changed.
        defer {
            for ws in workspaces {
                state.endPRRefresh(workspaceId: ws.id)
            }
        }

        let identifier: RepoIdentifier
        switch await resolvedIdentifier(for: repo) {
        case .resolved(let id):
            identifier = id
        case .notOnGitHub:
            // No GitHub remote → no PR is possible. Without this, the
            // PR panel sits on "Loading PR…" forever because the snapshot
            // never gets written.
            recordError("Repository has no GitHub remote.", for: workspaces, state: state)
            return
        case .deferred:
            // resolvedIdentifier already bumped githubFailures + status.
            // Surface a placeholder so the panel doesn't stall on the
            // initial "Loading PR…" — the next successful poll overwrites.
            recordError("Couldn't reach GitHub. Retrying…", for: workspaces, state: state)
            return
        }

        do {
            let result = try await GitHubRunner.batchFetchPRs(
                repo: identifier,
                branches: workspaces.map(\.branchName),
                cwd: repo.path
            )
            loops[repoId]?.githubFailures = 0
            updateStatus(.ok)
            state.activityLog.record(
                .prPoll,
                "Polled GitHub (\(workspaces.count) branch\(workspaces.count == 1 ? "" : "es"))",
                repoId: repoId
            )
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
            loops[repoId]?.githubFailures += 1
            state.activityLog.record(.error, "GitHub poll: gh CLI not found", repoId: repoId)
            recordError("gh CLI not found. Install via `brew install gh`.", for: workspaces, state: state)
        } catch GitHubRunner.Error.authRequired {
            updateStatus(.authRequired)
            loops[repoId]?.githubFailures += 1
            state.activityLog.record(.error, "GitHub poll: gh not authenticated", repoId: repoId)
            recordError("gh not authenticated. Run `gh auth login` in a terminal.", for: workspaces, state: state)
        } catch {
            loops[repoId]?.githubFailures += 1
            print("PRTracker.pollGitHub failed for \(identifier.owner)/\(identifier.name): \(error)")
            state.activityLog.record(
                .error,
                "GitHub poll failed: \(error.localizedDescription)",
                repoId: repoId
            )
            recordError(error.localizedDescription, for: workspaces, state: state)
        }
    }

    /// Write `.error` only for workspaces with no prior snapshot. Preserves
    /// the last successful `.loaded` / `.absent` across transient outages so
    /// the user keeps seeing real data while the next poll catches up.
    private func recordError(
        _ message: String,
        for workspaces: [Workspace],
        state: AppState
    ) {
        for ws in workspaces {
            switch state.workspaceState(for: ws.id).pr {
            case .loading, .error:
                state.applyPR(.error(message), for: ws.id)
            case .absent, .loaded:
                continue
            }
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
            loops[repo.id]?.githubFailures += 1
            return .deferred
        } catch GitHubRunner.Error.authRequired {
            updateStatus(.authRequired)
            loops[repo.id]?.githubFailures += 1
            return .deferred
        } catch {
            loops[repo.id]?.githubFailures += 1
            return .deferred
        }
    }

    /// 30s, 60s, 120s, 240s, capped at 300s while errored. Otherwise 15s
    /// when any workspace has an active check, 60s when quiescent.
    private func nextGitHubInterval(repoId: String) -> Double {
        let failures = loops[repoId]?.githubFailures ?? 0
        if failures > 0 {
            return min(300, 30 * pow(2, Double(failures - 1)))
        }
        guard let state else { return 60 }
        let wsIds = (state.workspacesByRepo[repoId] ?? []).map(\.id)
        let anyActive = wsIds.contains(where: { id in
            if case let .loaded(_, checks) = state.workspaceState(for: id).pr {
                return checks.contains(where: \.isActive)
            }
            return false
        })
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
