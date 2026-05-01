import Foundation
import GRDB

/// A git repository the user has added to Jetforge.
/// Workspaces are git worktrees rooted off this repo.
struct Repository: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var path: String
    var defaultBranch: String
    var createdAt: Date
    var lastOpenedAt: Date?

    static let databaseTableName = "repositories"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let path = Column(CodingKeys.path)
        static let defaultBranch = Column(CodingKeys.defaultBranch)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastOpenedAt = Column(CodingKeys.lastOpenedAt)
    }

    static let workspaces = hasMany(Workspace.self)

    var workspaces: QueryInterfaceRequest<Workspace> { request(for: Repository.workspaces) }
}
