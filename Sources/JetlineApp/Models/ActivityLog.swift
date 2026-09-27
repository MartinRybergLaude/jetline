import Foundation
import Observation

/// In-memory, capped ring buffer of background activity. Lives only for
/// the app's session — no persistence. Intended as a debug aid surfaced
/// through the hidden Activity Log window; not a user-facing feature.
///
/// Pinned to the main actor so `PRTracker`, `AppState`, etc. can append
/// synchronously from their own isolation domain and SwiftUI observation
/// stays cheap.
@MainActor
@Observable
final class ActivityLog {
    static let cap = 1000

    private(set) var events: [ActivityEvent] = []

    /// Fires for every recorded event. The engine uses it to forward its
    /// log to connected clients.
    @ObservationIgnored var onRecord: ((ActivityEvent) -> Void)?

    func record(
        _ kind: ActivityEvent.Kind,
        _ message: String,
        repoId: String? = nil,
        workspaceId: String? = nil
    ) {
        let event = ActivityEvent(
            timestamp: Date(),
            kind: kind,
            message: message,
            repoId: repoId,
            workspaceId: workspaceId
        )
        append(event)
        onRecord?(event)
    }

    /// Adopt an event recorded elsewhere (a client mirroring its engine's
    /// log).
    func append(_ event: ActivityEvent) {
        events.append(event)
        if events.count > Self.cap {
            events.removeFirst(events.count - Self.cap)
        }
    }

    func clear() {
        events.removeAll()
    }
}

struct ActivityEvent: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    let timestamp: Date
    let kind: Kind
    let message: String
    let repoId: String?
    let workspaceId: String?

    enum Kind: String, Hashable, CaseIterable, Codable, Sendable {
        case fetch
        case fastForward
        case prPoll
        case gitAction
        case lifecycle
        case error
    }
}
