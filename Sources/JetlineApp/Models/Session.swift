import Foundation
import GRDB

/// A single PTY-backed agent run inside a workspace.
/// One workspace can have many sessions (e.g. switching between
/// claude and codex, or starting a fresh run).
struct Session: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var workspaceId: String
    var title: String
    var agent: Workspace.AgentKind
    var startedAt: Date
    var endedAt: Date?

    static let databaseTableName = "sessions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let workspaceId = Column(CodingKeys.workspaceId)
        static let title = Column(CodingKeys.title)
        static let agent = Column(CodingKeys.agent)
        static let startedAt = Column(CodingKeys.startedAt)
        static let endedAt = Column(CodingKeys.endedAt)
    }

    static let workspace = belongsTo(Workspace.self)
    var workspace: QueryInterfaceRequest<Workspace> { request(for: Session.workspace) }
}
