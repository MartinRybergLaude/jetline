import Foundation
import GRDB

/// A workspace is a git worktree on a feature branch where an agent runs.
/// Lives at `~/.jetline/worktrees/<repoFolder>/<shortName>` where
/// `<repoFolder>` is the repo-name slug and `<shortName>` is a star name
/// allocated by `WorktreeNamer` (legacy rows: UUIDs for both components —
/// the stored `worktreePath` is authoritative either way).
struct Workspace: Codable, Identifiable, Hashable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var repositoryId: String
    var name: String
    var branchName: String
    var baseBranch: String
    var pullRequestNumber: Int?
    var pullRequestURL: String?
    var worktreePath: String
    var agent: AgentKind
    var createdAt: Date
    var lastActiveAt: Date
    /// Manual sidebar ordering within the repository section. Lower = nearer
    /// the top. New workspaces are inserted below the current min so they
    /// land at the top; reorders rewrite the column with 0…n-1 values.
    var sortIndex: Int = 0
    /// The workspace whose agent created this one through Jetline's agent
    /// tools. That agent may change it; agents elsewhere may not.
    var createdByWorkspaceId: String?
    /// Why the workspace exists, left by the agent that created it. Shown
    /// (never sent) as the first chat's draft.
    var note: String?

    enum AgentKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case claude
        case codex
        case vibe
        case shell

        var displayName: String {
            switch self {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .vibe: return "Mistral Vibe"
            case .shell: return "Terminal"
            }
        }

        var executableName: String {
            switch self {
            case .claude: return "claude"
            case .codex: return "codex"
            case .vibe: return "vibe"
            case .shell: return "shell"
            }
        }
    }

    static let databaseTableName = "workspaces"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let repositoryId = Column(CodingKeys.repositoryId)
        static let name = Column(CodingKeys.name)
        static let branchName = Column(CodingKeys.branchName)
        static let baseBranch = Column(CodingKeys.baseBranch)
        static let pullRequestNumber = Column(CodingKeys.pullRequestNumber)
        static let pullRequestURL = Column(CodingKeys.pullRequestURL)
        static let worktreePath = Column(CodingKeys.worktreePath)
        static let agent = Column(CodingKeys.agent)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastActiveAt = Column(CodingKeys.lastActiveAt)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let createdByWorkspaceId = Column(CodingKeys.createdByWorkspaceId)
        static let note = Column(CodingKeys.note)
    }

    static let repository = belongsTo(Repository.self)

    var repository: QueryInterfaceRequest<Repository> { request(for: Workspace.repository) }
}
