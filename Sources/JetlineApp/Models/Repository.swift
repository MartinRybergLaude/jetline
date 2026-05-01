import Foundation
import GRDB

/// A git repository the user has added to Jetline.
/// Workspaces are git worktrees rooted off this repo.
struct Repository: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var path: String
    /// May be a local branch (`main`) or a remote-tracking ref (`origin/main`).
    var defaultBranch: String
    var createdAt: Date
    var lastOpenedAt: Date?

    var remoteOrigin: String = "origin"
    /// `nil` means "inherit `AppSettings.globalBranchPrefix`".
    var branchPrefix: String?
    var setupScript: String?
    var runScript: String?
    /// When true, starting a run stops every other active runner in the same repo.
    var runExclusive: Bool = false
    var archiveScript: String?

    /// Trimmed, non-empty variants of the script fields. Returns `nil` when
    /// blank so callers can use `if let` instead of repeated trim+isEmpty.
    var trimmedSetupScript: String? { setupScript?.nonBlank }
    var trimmedRunScript: String? { runScript?.nonBlank }
    var trimmedArchiveScript: String? { archiveScript?.nonBlank }

    static let databaseTableName = "repositories"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let path = Column(CodingKeys.path)
        static let defaultBranch = Column(CodingKeys.defaultBranch)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastOpenedAt = Column(CodingKeys.lastOpenedAt)
        static let remoteOrigin = Column(CodingKeys.remoteOrigin)
        static let branchPrefix = Column(CodingKeys.branchPrefix)
        static let setupScript = Column(CodingKeys.setupScript)
        static let runScript = Column(CodingKeys.runScript)
        static let runExclusive = Column(CodingKeys.runExclusive)
        static let archiveScript = Column(CodingKeys.archiveScript)
    }

    static let workspaces = hasMany(Workspace.self)

    var workspaces: QueryInterfaceRequest<Workspace> { request(for: Repository.workspaces) }
}
