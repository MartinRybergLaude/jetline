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

    enum Theme: String, Codable, CaseIterable, DatabaseValueConvertible {
        case system
        case light
        case dark
    }

    static let databaseTableName = "app_settings"
}
