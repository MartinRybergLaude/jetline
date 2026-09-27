#if os(macOS)
import Foundation

/// The views' handle on the engine's PR tracker.
@MainActor
final class PRTrackerProxy {
    private weak var connection: EngineConnection?

    init(connection: EngineConnection) {
        self.connection = connection
    }

    /// Poll now instead of on the next tick.
    func kick(workspaceId: String) {
        connection?.send(API.KickPR(workspaceId: workspaceId, repoId: nil))
    }

    func kick(repoId: String) {
        connection?.send(API.KickPR(workspaceId: nil, repoId: repoId))
    }
}

/// The views' handle on the engine's PR conversation loader. Loads land in
/// `WorkspaceState.conversation` through the engine's events; writes return
/// an error message, or nil on success.
@MainActor
final class PRConversationStore {
    private weak var connection: EngineConnection?

    init(connection: EngineConnection) {
        self.connection = connection
    }

    func refresh(workspaceId: String, force: Bool = false) async {
        _ = try? await connection?.call(API.RefreshConversation(workspaceId: workspaceId, force: force))
    }

    func postComment(workspaceId: String, body: String) async -> String? {
        await write { try await $0.call(API.PostComment(workspaceId: workspaceId, body: body)) }
    }

    func reply(workspaceId: String, threadId: String, body: String, refreshAfter: Bool = true) async -> String? {
        await write {
            try await $0.call(API.ReplyToThread(workspaceId: workspaceId, threadId: threadId, body: body, refreshAfter: refreshAfter))
        }
    }

    func setResolved(workspaceId: String, threadId: String, resolved: Bool) async -> String? {
        await write { try await $0.call(API.SetThreadResolved(workspaceId: workspaceId, threadId: threadId, resolved: resolved)) }
    }

    private func write(_ body: (EngineConnection) async throws -> String?) async -> String? {
        guard let connection else { return WireError.disconnected.message }
        do {
            return try await body(connection)
        } catch {
            return (error as? WireError)?.message ?? error.localizedDescription
        }
    }
}
#endif
