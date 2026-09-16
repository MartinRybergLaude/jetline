import Foundation

/// On-demand loader for PR comment streams, plus the write path for
/// replying and resolving.
///
/// Separate from `PRTracker` because the cost profile is the opposite:
/// the tracker polls every workspace in every repo on a timer and must stay
/// cheap, while a conversation is one PR's worth of full comment bodies
/// fetched only while the Comments tab is actually looking at it. The
/// panel drives the cadence via its `.task` loop; this type only
/// de-duplicates concurrent requests and suppresses redundant ones.
@MainActor
final class PRConversationStore {
    /// A load that lands within this window of the previous one is served
    /// from what's already in `WorkspaceState`. Guards against tab flipping
    /// turning into a request per switch.
    private static let freshness: TimeInterval = 10

    private weak var state: AppState?
    private var inFlight: [String: Task<Void, Never>] = [:]
    private var lastLoaded: [String: Date] = [:]
    /// Owner/name resolved here when `PRTracker` hasn't cached it yet — on a
    /// cold launch the Comments tab can open before the first GitHub poll
    /// completes, and waiting a full poll interval to show anything is worse
    /// than one extra `gh repo view`.
    private var fallbackIdentifiers: [String: RepoIdentifier] = [:]

    init(state: AppState) {
        self.state = state
    }

    // MARK: - Reads

    /// Load (or reload) the conversation for a workspace. Returns once the
    /// snapshot has been written, so a polling caller can pace itself off
    /// the actual round trip rather than a fixed schedule.
    func refresh(workspaceId: String, force: Bool = false) async {
        if let existing = inFlight[workspaceId] {
            await existing.value
            return
        }
        if !force,
           let last = lastLoaded[workspaceId],
           Date().timeIntervalSince(last) < Self.freshness {
            return
        }

        let task = Task<Void, Never> { [weak self] in
            await self?.load(workspaceId: workspaceId)
        }
        inFlight[workspaceId] = task
        await task.value
        inFlight[workspaceId] = nil
    }

    /// Drop cached freshness so the next `refresh` definitely hits the
    /// network. Used when the workspace's PR snapshot reports new activity.
    func invalidate(workspaceId: String) {
        lastLoaded.removeValue(forKey: workspaceId)
    }

    private func load(workspaceId: String) async {
        guard let state,
              let workspace = state.workspaceById(workspaceId),
              let repo = state.repositories.first(where: { $0.id == workspace.repositoryId })
        else { return }

        guard let number = prNumber(for: workspaceId, workspace: workspace, state: state) else {
            state.applyConversation(.idle, for: workspaceId)
            return
        }

        // Only show the spinner when there's nothing to show instead. A
        // background reload of an open panel keeps the current thread list
        // on screen until the new one is ready.
        if state.workspaceState(for: workspaceId).conversation.conversation == nil {
            state.applyConversation(.loading, for: workspaceId)
        }

        guard let identifier = await resolveIdentifier(repo: repo, state: state) else {
            state.applyConversation(.error("Repository has no GitHub remote."), for: workspaceId)
            return
        }

        do {
            let conversation = try await GitHubRunner.fetchConversation(
                repo: identifier,
                number: number,
                cwd: repo.path
            )
            if let conversation {
                state.applyConversation(.loaded(conversation), for: workspaceId)
                lastLoaded[workspaceId] = Date()
            } else {
                state.applyConversation(
                    .error("Pull request #\(number) is no longer available."),
                    for: workspaceId
                )
            }
        } catch {
            state.activityLog.record(
                .error,
                "Comment fetch failed: \(error.localizedDescription)",
                repoId: repo.id,
                workspaceId: workspaceId
            )
            // Preserve the last good conversation across a transient outage,
            // the same way `PRTracker` preserves PR snapshots.
            if state.workspaceState(for: workspaceId).conversation.conversation == nil {
                state.applyConversation(.error(error.localizedDescription), for: workspaceId)
            }
        }
    }

    /// Durable PR identity first; fall back to whatever the current PR
    /// snapshot discovered, which covers the window between a PR appearing
    /// and the identity being persisted.
    private func prNumber(for workspaceId: String, workspace: Workspace, state: AppState) -> Int? {
        if let number = workspace.pullRequestNumber { return number }
        if case let .loaded(pr, _) = state.workspaceState(for: workspaceId).pr { return pr.number }
        return nil
    }

    private func resolveIdentifier(repo: Repository, state: AppState) async -> RepoIdentifier? {
        if let cached = state.repoMetadataByRepo[repo.id] { return cached }
        if let cached = fallbackIdentifiers[repo.id] { return cached }
        guard let resolved = try? await GitHubRunner.repoIdentifier(cwd: repo.path) else { return nil }
        fallbackIdentifiers[repo.id] = resolved
        state.applyRepoMetadata(resolved, for: repo.id)
        return resolved
    }

    // MARK: - Writes

    /// Post a top-level comment on the PR. Returns an error message on
    /// failure, `nil` on success.
    func postComment(workspaceId: String, body: String) async -> String? {
        await mutate(workspaceId: workspaceId, describedAs: "Posted PR comment") { context in
            try await GitHubRunner.addIssueComment(
                pullRequestId: context.conversation.pullRequestId,
                body: body,
                cwd: context.repoPath
            )
        }
    }

    func reply(workspaceId: String, threadId: String, body: String) async -> String? {
        await mutate(workspaceId: workspaceId, describedAs: "Replied to review thread") { context in
            try await GitHubRunner.replyToReviewThread(
                threadId: threadId,
                body: body,
                cwd: context.repoPath
            )
        }
    }

    func setResolved(workspaceId: String, threadId: String, resolved: Bool) async -> String? {
        let label = resolved ? "Resolved review thread" : "Unresolved review thread"
        return await mutate(workspaceId: workspaceId, describedAs: label) { context in
            try await GitHubRunner.setReviewThreadResolved(
                threadId: threadId,
                resolved: resolved,
                cwd: context.repoPath
            )
        }
    }

    private struct MutationContext {
        let repoPath: String
        let repoId: String
        let conversation: PRConversation
    }

    /// Runs a write, then forces a reload so the panel shows GitHub's own
    /// view of the result rather than an optimistic guess — replies come
    /// back with server-assigned ids and rendered bodies, and a resolve can
    /// be rejected by permissions we only partly model.
    private func mutate(
        workspaceId: String,
        describedAs description: String,
        _ body: @escaping (MutationContext) async throws -> Void
    ) async -> String? {
        guard let state,
              let workspace = state.workspaceById(workspaceId),
              let repo = state.repositories.first(where: { $0.id == workspace.repositoryId }),
              let conversation = state.workspaceState(for: workspaceId).conversation.conversation
        else {
            return "No pull request loaded for this workspace."
        }

        do {
            try await body(MutationContext(
                repoPath: repo.path,
                repoId: repo.id,
                conversation: conversation
            ))
        } catch {
            state.activityLog.record(
                .error,
                "\(description) failed: \(error.localizedDescription)",
                repoId: repo.id,
                workspaceId: workspaceId
            )
            return error.localizedDescription
        }

        state.activityLog.record(
            .gitAction,
            "\(description) on #\(conversation.number)",
            repoId: repo.id,
            workspaceId: workspaceId
        )
        invalidate(workspaceId: workspaceId)
        await refresh(workspaceId: workspaceId, force: true)
        // Unresolved-thread and comment counts feed the sidebar badge and
        // the PR panel, and they're owned by the tracker.
        state.prTracker.kick(workspaceId: workspaceId)
        return nil
    }
}
