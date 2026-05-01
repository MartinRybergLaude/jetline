import Foundation
import GRDB

/// Persisted single-row settings.
struct AppSettings: Codable, FetchableRecord, PersistableRecord {
    static let singletonId = "singleton"

    var id: String = AppSettings.singletonId
    var defaultAgent: Workspace.AgentKind = .claude
    var claudeBinaryPath: String?
    var codexBinaryPath: String?
    var terminalFontFamily: String = "SF Mono"
    var terminalFontSize: Double = 13
    var theme: Theme = .system
    /// Prefix prepended to generated branch names for new workspaces. Each
    /// repo can override via `Repository.branchPrefix`. Trailing slash is
    /// preserved as-is so users can use either `name/` or `name-`.
    var globalBranchPrefix: String = "jetline/"

    enum Theme: String, Codable, CaseIterable, DatabaseValueConvertible {
        case system
        case light
        case dark
    }

    static let databaseTableName = "app_settings"
}
