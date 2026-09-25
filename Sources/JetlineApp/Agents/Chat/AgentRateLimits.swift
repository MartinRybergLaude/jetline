import Foundation
import Observation

/// Plan usage per provider. The limits are the account's, not a chat's, so
/// every chat shows the latest any of them reported.
@MainActor
@Observable
final class AgentRateLimits {
    static let shared = AgentRateLimits()

    private(set) var windows: [AgentProviderKind: [AgentRateLimit]] = [:]

    func merge(_ updates: [AgentRateLimit], for provider: AgentProviderKind) {
        var list = windows[provider] ?? []
        for update in updates {
            if let index = list.firstIndex(where: { $0.id == update.id }) {
                list[index] = update
            } else {
                list.append(update)
            }
        }
        list.sort { $0.id < $1.id }
        if windows[provider] != list { windows[provider] = list }
    }
}
