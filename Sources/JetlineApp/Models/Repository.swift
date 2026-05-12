import Foundation
import GRDB

/// How the branch prefix for new workspaces in a repository is derived.
/// Stored as the raw string in `Repository.branchPrefixMode`.
enum BranchPrefixMode: String, CaseIterable, Hashable {
    /// Slugged `git config user.name` followed by `/`. The most useful
    /// default when collaborators share a remote — branches are clearly
    /// owned without each user typing their name into settings.
    case username
    /// User-supplied prefix (the existing `branchPrefix` string).
    case custom
    /// No prefix; branch names start with the workspace slug directly.
    case none
}

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
    /// Manual sidebar ordering. Lower = nearer the top. New repos are
    /// inserted above the current min so they land at the top; reorders
    /// rewrite the column with consecutive 0…n-1 values.
    var sortIndex: Int = 0

    var remoteOrigin: String = "origin"
    /// Custom prefix used when `branchPrefixMode` is `.custom`.
    var branchPrefix: String?
    /// Discriminator for the per-repo branch-prefix UI. `nil` is legacy and
    /// resolves to `.custom` if `branchPrefix` is set, else `.username`.
    /// Recognised values: `username`, `custom`, `none`.
    var branchPrefixMode: String?
    var setupScript: String?
    var runScript: String?
    /// When true, starting a run stops every other active runner in the same repo.
    var runExclusive: Bool = false
    var archiveScript: String?

    /// Last merge strategy the user picked from the merge confirmation
    /// dialog for this repo, as `MergeMethod.rawValue`. `nil` → no
    /// preference yet, dialog uses the first allowed method as default.
    var lastMergeMethod: String?

    /// Per-repo overrides for the git-action prompts. `nil`/blank falls
    /// through to `AppSettings.<actionPrompt>` and finally
    /// `GitActionPrompts.defaults`.
    var commitPrompt: String?
    var createPRPrompt: String?
    var pullUpdatesPrompt: String?
    var rebaseOnMainPrompt: String?
    var fixCIPrompt: String?
    var fixCommentsPrompt: String?
    var reviewPrompt: String?

    /// Trimmed, non-empty variants of the script fields. Returns `nil` when
    /// blank so callers can use `if let` instead of repeated trim+isEmpty.
    var trimmedSetupScript: String? { setupScript?.nonBlank }
    var trimmedRunScript: String? { runScript?.nonBlank }
    var trimmedArchiveScript: String? { archiveScript?.nonBlank }

    /// Strip the `<remoteOrigin>/` prefix from a remote-tracking ref so the
    /// caller has the local-branch form. `git for-each-ref` emits the prefixed
    /// form; the worktree + workspace use the local name.
    func localName(forRemoteRef ref: String) -> String {
        let prefix = "\(remoteOrigin)/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    /// Lookup helper for the action-prompt fallback chain. Mirrors
    /// `AppSettings.prompt(for:)` so callers can chain the two.
    func prompt(for action: GitAction) -> String? {
        action.repositoryKeyPath.flatMap { self[keyPath: $0] }
    }

    static let databaseTableName = "repositories"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let name = Column(CodingKeys.name)
        static let path = Column(CodingKeys.path)
        static let defaultBranch = Column(CodingKeys.defaultBranch)
        static let createdAt = Column(CodingKeys.createdAt)
        static let lastOpenedAt = Column(CodingKeys.lastOpenedAt)
        static let sortIndex = Column(CodingKeys.sortIndex)
        static let remoteOrigin = Column(CodingKeys.remoteOrigin)
        static let branchPrefix = Column(CodingKeys.branchPrefix)
        static let branchPrefixMode = Column(CodingKeys.branchPrefixMode)
        static let setupScript = Column(CodingKeys.setupScript)
        static let runScript = Column(CodingKeys.runScript)
        static let runExclusive = Column(CodingKeys.runExclusive)
        static let archiveScript = Column(CodingKeys.archiveScript)
        static let lastMergeMethod = Column(CodingKeys.lastMergeMethod)
        static let commitPrompt = Column(CodingKeys.commitPrompt)
        static let createPRPrompt = Column(CodingKeys.createPRPrompt)
        static let pullUpdatesPrompt = Column(CodingKeys.pullUpdatesPrompt)
        static let rebaseOnMainPrompt = Column(CodingKeys.rebaseOnMainPrompt)
        static let fixCIPrompt = Column(CodingKeys.fixCIPrompt)
        static let fixCommentsPrompt = Column(CodingKeys.fixCommentsPrompt)
        static let reviewPrompt = Column(CodingKeys.reviewPrompt)
    }

    static let workspaces = hasMany(Workspace.self)

    var workspaces: QueryInterfaceRequest<Workspace> { request(for: Repository.workspaces) }
}
