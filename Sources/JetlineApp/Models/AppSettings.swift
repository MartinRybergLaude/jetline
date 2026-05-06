import Foundation
import GRDB

/// Persisted single-row settings.
struct AppSettings: Codable, FetchableRecord, PersistableRecord {
    static let singletonId = "singleton"

    var id: String = AppSettings.singletonId
    var defaultAgent: Workspace.AgentKind = .claude
    var claudeBinaryPath: String?
    var codexBinaryPath: String?
    var mistralBinaryPath: String?
    var terminalFontFamily: String = "SF Mono"
    var terminalFontSize: Double = 13
    var theme: Theme = .system
    /// Comma-separated raw values of agents the user has hidden from the
    /// new-tab menu. Stored as a string so adding new agents doesn't require
    /// a schema migration.
    var hiddenAgents: String = ""
    /// External app used by the workspace toolbar's "Open in" button.
    var defaultOpenInApp: OpenInApp = .finder

    /// Agent that executes commit / PR / CI / comments actions when the
    /// inspector's git action bar is used. `nil` → use `defaultAgent`.
    var gitAgent: Workspace.AgentKind?
    /// Agent that runs the "Review" action. `nil` → use `defaultAgent`.
    var reviewAgent: Workspace.AgentKind?

    /// User overrides for the prompt sent to the agent for each action.
    /// Empty/nil falls back to `GitActionPrompts.defaults`.
    var commitPrompt: String?
    var createPRPrompt: String?
    var pullUpdatesPrompt: String?
    var rebaseOnMainPrompt: String?
    var fixCIPrompt: String?
    var fixCommentsPrompt: String?
    var reviewPrompt: String?

    enum Theme: String, Codable, CaseIterable, DatabaseValueConvertible {
        case system
        case light
        case dark
    }

    static let databaseTableName = "app_settings"

    func isAgentVisible(_ agent: Workspace.AgentKind) -> Bool {
        !hiddenAgentSet.contains(agent)
    }

    mutating func setAgent(_ agent: Workspace.AgentKind, visible: Bool) {
        var set = hiddenAgentSet
        if visible { set.remove(agent) } else { set.insert(agent) }
        hiddenAgents = set.map(\.rawValue).sorted().joined(separator: ",")
    }

    private var hiddenAgentSet: Set<Workspace.AgentKind> {
        Set(hiddenAgents
            .split(separator: ",")
            .compactMap { Workspace.AgentKind(rawValue: String($0)) })
    }

    /// Lookup helper for the action-prompt fallback chain. `mergePR`
    /// returns `nil` because it doesn't spawn an agent.
    func prompt(for action: GitAction) -> String? {
        action.settingsKeyPath.flatMap { self[keyPath: $0] }
    }
}
