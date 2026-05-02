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
    /// Prefix prepended to generated branch names for new workspaces. Each
    /// repo can override via `Repository.branchPrefix`. Trailing slash is
    /// preserved as-is so users can use either `name/` or `name-`.
    var globalBranchPrefix: String = "jetline/"
    /// Comma-separated raw values of agents the user has hidden from the
    /// new-tab menu. Stored as a string so adding new agents doesn't require
    /// a schema migration.
    var hiddenAgents: String = ""
    /// External app used by the workspace toolbar's "Open in" button.
    var defaultOpenInApp: OpenInApp = .finder

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
}
