import Foundation

/// In-memory, capped ring buffer of background activity. Lives only for
/// the app's session — no persistence. Intended as a debug aid surfaced
/// through the hidden Activity Log window; not a user-facing feature.
///
/// Pinned to the main actor so `PRTracker`, `AppState`, etc. can append
/// synchronously from their own isolation domain and SwiftUI observation
/// stays cheap.
@MainActor
final class ActivityLog: ObservableObject {
    static let cap = 1000

    @Published private(set) var events: [ActivityEvent] = []

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
        events.append(event)
        if events.count > Self.cap {
            events.removeFirst(events.count - Self.cap)
        }
    }

    func clear() {
        events.removeAll()
    }
}

struct ActivityEvent: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let kind: Kind
    let message: String
    let repoId: String?
    let workspaceId: String?

    enum Kind: String, Hashable, CaseIterable {
        case fetch
        case fastForward
        case prPoll
        case gitAction
        case lifecycle
        case error
    }
}
