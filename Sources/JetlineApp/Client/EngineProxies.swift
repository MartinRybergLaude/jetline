#if os(macOS)
import Foundation

/// The views' handle on the engine's PR tracker.
@MainActor
final class PRTrackerProxy {
    /// The engine owning a workspace (or repo).
    private let route: (_ workspaceId: String?, _ repoId: String?) -> EngineConnection?

    init(route: @escaping (_ workspaceId: String?, _ repoId: String?) -> EngineConnection?) {
        self.route = route
    }

    /// Poll now instead of on the next tick.
    func kick(workspaceId: String) {
        route(workspaceId, nil)?.send(API.KickPR(workspaceId: workspaceId, repoId: nil))
    }

    func kick(repoId: String) {
        route(nil, repoId)?.send(API.KickPR(workspaceId: nil, repoId: repoId))
    }
}

/// The views' handle on the engine's PR conversation loader. Loads land in
/// `WorkspaceState.conversation` through the engine's events; writes return
/// an error message, or nil on success.
@MainActor
final class PRConversationStore {
    private let route: (_ workspaceId: String) -> EngineConnection?

    init(route: @escaping (_ workspaceId: String) -> EngineConnection?) {
        self.route = route
    }

    func refresh(workspaceId: String, force: Bool = false) async {
        _ = try? await route(workspaceId)?.call(API.RefreshConversation(workspaceId: workspaceId, force: force))
    }

    func postComment(workspaceId: String, body: String) async -> String? {
        await write(workspaceId) { try await $0.call(API.PostComment(workspaceId: workspaceId, body: body)) }
    }

    func reply(workspaceId: String, threadId: String, body: String, refreshAfter: Bool = true) async -> String? {
        await write(workspaceId) {
            try await $0.call(API.ReplyToThread(workspaceId: workspaceId, threadId: threadId, body: body, refreshAfter: refreshAfter))
        }
    }

    func setResolved(workspaceId: String, threadId: String, resolved: Bool) async -> String? {
        await write(workspaceId) { try await $0.call(API.SetThreadResolved(workspaceId: workspaceId, threadId: threadId, resolved: resolved)) }
    }

    private func write(_ workspaceId: String, _ body: (EngineConnection) async throws -> String?) async -> String? {
        guard let connection = route(workspaceId) else { return WireError.disconnected.message }
        do {
            return try await body(connection)
        } catch {
            return (error as? WireError)?.message ?? error.localizedDescription
        }
    }
}
#endif
