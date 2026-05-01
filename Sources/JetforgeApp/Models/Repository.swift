import Foundation
import GRDB

/// A git repository the user has added to Jetforge.
/// Workspaces are git worktrees rooted off this repo.
struct Repository: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var path: String
    /// Ref new workspaces branch off (e.g. `origin/main`, `main`). Stored as
    /// the literal git rev string so it can be a remote-tracking ref or local.
    var defaultBranch: String
    var createdAt: Date
    var lastOpenedAt: Date?

    /// Remote name used for `git push` / PR operations. Defaults to `origin`.
    var remoteOrigin: String = "origin"
    /// Optional branch-name prefix for new workspaces. When `nil` or empty,
    /// the global default in `AppSettings.globalBranchPrefix` is used.
    var branchPrefix: String?
    /// Shell script run once after a worktree is created (`pnpm install`,
    /// symlink .env files, etc.). Has `JETFORGE_ROOT_PATH` available.
    var setupScript: String?
    /// Shell script run when the user presses Run (typically `npm run dev`).
    var runScript: String?
    /// If true, only one workspace per repo can have its run script active;
    /// starting a new run stops any other.
    var runExclusive: Bool = false
    /// Shell script run before a worktree is deleted (`rm -rf node_modules`).
    var archiveScript: String?

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
