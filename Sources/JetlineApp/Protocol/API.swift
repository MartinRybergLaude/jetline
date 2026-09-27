import Foundation

/// Every request a client can make of the engine. Grouped by what they act
/// on; `method` strings are the wire names and must stay stable within a
/// protocol version.
enum API {
    // MARK: Session

    struct Hello: RPC {
        typealias Response = HelloResult
        static let method = "hello"
        var protocolVersion: Int
        var clientName: String
    }

    struct HelloResult: Codable, Sendable {
        var protocolVersion: Int
        var engineVersion: String
        var hostName: String
        var platform: String
        var homeDirectory: String
        var dataDirectory: String
        var snapshot: EngineSnapshot
        /// Optional capabilities: "tunnels" (port forwarding). Absent from
        /// engines that predate the field.
        var features: [String]? = nil
    }

    static let tunnelsFeature = "tunnels"

    /// Start reporting this machine's listening TCP ports (`.ports` events
    /// on every change) and return the current list.
    struct WatchPorts: RPC {
        typealias Response = [ListeningPort]
        static let method = "ports.watch"
    }

    /// Which workspace this client is looking at. Focused workspaces stay
    /// awake (no idle pause) and get the PR tracker's faster cadence.
    struct SetFocus: RPC {
        typealias Response = Empty
        static let method = "session.focus"
        var workspaceId: String?
    }

    // MARK: Repositories

    struct AddRepository: RPC {
        typealias Response = Repository
        static let method = "repo.add"
        var path: String
    }

    struct RemoveRepository: RPC {
        typealias Response = Empty
        static let method = "repo.remove"
        var repoId: String
    }

    struct UpdateRepository: RPC {
        typealias Response = Empty
        static let method = "repo.update"
        var repository: Repository
    }

    struct ReorderRepositories: RPC {
        typealias Response = Empty
        static let method = "repo.reorder"
        var orderedIds: [String]
    }

    struct RepoRefs: RPC {
        typealias Response = RepoRefsResult
        static let method = "repo.refs"
        var repoId: String
    }

    struct RepoRefsResult: Codable, Sendable {
        var remotes: [String]
        var baseRefs: [String]
        var usernameSlug: String
    }

    struct RemoteBranches: RPC {
        typealias Response = [RemoteBranch]
        static let method = "repo.remoteBranches"
        var repoId: String
    }

    struct RemoteBranch: Codable, Sendable, Hashable {
        var ref: String
        var lastCommitAt: Date
    }

    struct OpenPullRequests: RPC {
        typealias Response = OpenPullRequestsResult
        static let method = "repo.openPRs"
        var repoId: String
    }

    enum OpenPullRequestsResult: Codable, Sendable {
        case loaded(RepoIdentifier, [PRSummary])
        case noGitHubRemote
        case ghMissing
        case authRequired
    }

    // MARK: Workspaces

    struct CreateWorkspace: RPC {
        typealias Response = CreateWorkspaceResult
        static let method = "workspace.create"
        var repoId: String
        var name: String
        /// Force-remove a worktree already holding the branch.
        var overrideExisting: Bool = false
    }

    struct ImportBranch: RPC {
        typealias Response = CreateWorkspaceResult
        static let method = "workspace.importBranch"
        var repoId: String
        /// `origin/feature` for a remote branch, or a PR's head ref.
        var remoteRef: String?
        var pullRequest: PRSummary?
        var name: String
        var overrideExisting: Bool = false
    }

    enum CreateWorkspaceResult: Codable, Sendable {
        case created(Workspace)
        /// The branch is checked out elsewhere; ask before overriding.
        case branchInUse(branch: String, path: String, hasUncommittedChanges: Bool)
    }

    struct DeleteWorkspace: RPC {
        typealias Response = Empty
        static let method = "workspace.delete"
        var workspaceId: String
    }

    struct ReorderWorkspaces: RPC {
        typealias Response = Empty
        static let method = "workspace.reorder"
        var repoId: String
        var orderedIds: [String]
    }

    /// Bring a workspace's runtime up (watcher, diff, its chats and
    /// terminals — restoring or starting a first tab when it has none).
    struct ActivateWorkspace: RPC {
        typealias Response = ActivateResult
        static let method = "workspace.activate"
        var workspaceId: String
        var terminalSize: TerminalSize?
    }

    enum ActivateResult: Codable, Sendable {
        case ready
        /// The worktree is gone; the engine dropped the workspace.
        case missing
    }

    /// Stop everything running in a workspace. It stays in the sidebar.
    struct CloseWorkspace: RPC {
        typealias Response = Empty
        static let method = "workspace.close"
        var workspaceId: String
    }

    struct RefreshDiff: RPC {
        typealias Response = Empty
        static let method = "workspace.refreshDiff"
        var workspaceId: String
    }

    struct FullFileDiff: RPC {
        typealias Response = FileDiff?
        static let method = "workspace.fullFileDiff"
        var workspaceId: String
        var path: String
        var status: FileDiff.Status
        var mode: DiffMode
    }

    struct ListFiles: RPC {
        typealias Response = [String]
        static let method = "workspace.listFiles"
        var cwd: String
    }

    // MARK: Git actions

    struct StartGitAction: RPC {
        typealias Response = OpenedTab
        static let method = "git.startAction"
        var workspaceId: String
        var action: GitAction
        var terminalSize: TerminalSize?
    }

    /// Fast-path rebase / pull. Falls back to an agent tab on conflict.
    struct FastPathGitAction: RPC {
        typealias Response = OpenedTab?
        static let method = "git.fastPath"
        var workspaceId: String
        var action: GitAction
        var terminalSize: TerminalSize?
    }

    struct Merge: RPC {
        typealias Response = Empty
        static let method = "git.merge"
        var workspaceId: String
        var method: MergeMethod
    }

    struct SetAutoMerge: RPC {
        typealias Response = Empty
        static let method = "git.autoMerge"
        var workspaceId: String
        var enabled: Bool
        var method: MergeMethod?
    }

    // MARK: Pull requests

    struct RefreshPR: RPC {
        typealias Response = Empty
        static let method = "pr.refresh"
        var workspaceId: String
    }

    /// Wake the PR tracker without the user-initiated spinner.
    struct KickPR: RPC {
        typealias Response = Empty
        static let method = "pr.kick"
        var workspaceId: String?
        var repoId: String?
    }

    struct RefreshConversation: RPC {
        typealias Response = Empty
        static let method = "pr.refreshConversation"
        var workspaceId: String
        var force: Bool
    }

    /// Returns an error message, or nil on success.
    struct PostComment: RPC {
        typealias Response = String?
        static let method = "pr.comment"
        var workspaceId: String
        var body: String
    }

    struct ReplyToThread: RPC {
        typealias Response = String?
        static let method = "pr.reply"
        var workspaceId: String
        var threadId: String
        var body: String
        var refreshAfter: Bool = true
    }

    struct SetThreadResolved: RPC {
        typealias Response = String?
        static let method = "pr.resolve"
        var workspaceId: String
        var threadId: String
        var resolved: Bool
    }

    // MARK: Terminals

    struct CreateTerminal: RPC {
        typealias Response = TerminalInfo
        static let method = "terminal.create"
        var workspaceId: String
        var agent: Workspace.AgentKind
        var launchArgs: [String] = []
        var initialPrompt: String?
        var size: TerminalSize?
    }

    /// Start streaming a terminal's output. Bytes from `fromOffset` (or the
    /// whole retained buffer) are replayed first, then live output follows
    /// in `terminalOutput` frames.
    struct AttachTerminal: RPC {
        typealias Response = AttachResult
        static let method = "terminal.attach"
        var terminalId: String
        var fromOffset: UInt64?
    }

    struct AttachResult: Codable, Sendable {
        /// Oldest byte offset still retained.
        var bufferStart: UInt64
        /// Offset the replay starts at. Earlier than the client asked for
        /// means nothing was lost; later means the gap fell out of the
        /// buffer and the client should reset its screen first.
        var replayFrom: UInt64
        var info: TerminalInfo
    }

    struct DetachTerminal: RPC {
        typealias Response = Empty
        static let method = "terminal.detach"
        var terminalId: String
    }

    struct ResizeTerminal: RPC {
        typealias Response = Empty
        static let method = "terminal.resize"
        var terminalId: String
        var size: TerminalSize
    }

    struct InterruptTerminal: RPC {
        typealias Response = Empty
        static let method = "terminal.interrupt"
        var terminalId: String
    }

    /// Terminate a terminal tab's process and drop the tab.
    struct CloseTerminal: RPC {
        typealias Response = Empty
        static let method = "terminal.close"
        var terminalId: String
    }

    /// The retained output as text, for "copy output".
    struct TerminalText: RPC {
        typealias Response = String
        static let method = "terminal.text"
        var terminalId: String
    }

    // MARK: Run / setup scripts

    struct ToggleRun: RPC {
        typealias Response = Empty
        static let method = "run.toggle"
        var workspaceId: String
    }

    // MARK: Chats

    struct StartChat: RPC {
        typealias Response = ChatSummary
        static let method = "chat.start"
        var workspaceId: String
        var provider: AgentProviderKind
        var prompt: String?
    }

    struct ReopenChat: RPC {
        typealias Response = ChatSummary
        static let method = "chat.reopen"
        var workspaceId: String
        var threadId: String
    }

    struct CloseChat: RPC {
        typealias Response = Empty
        static let method = "chat.close"
        var chatId: String
    }

    struct ClosedChats: RPC {
        typealias Response = [ChatThreadRecord]
        static let method = "chat.closedList"
        var workspaceId: String
        var limit: Int
    }

    /// Full transcript now, patches after.
    struct SubscribeChat: RPC {
        typealias Response = ChatPatch
        static let method = "chat.subscribe"
        var chatId: String
    }

    struct UnsubscribeChat: RPC {
        typealias Response = Empty
        static let method = "chat.unsubscribe"
        var chatId: String
    }

    struct ChatCommand: RPC {
        typealias Response = ChatCommandResult
        static let method = "chat.command"
        var chatId: String
        var command: Command

        enum Command: Codable, Sendable {
            case connect
            case disconnect
            case send(text: String, images: [String])
            case removeQueued(id: UUID)
            case interrupt
            case respond(requestId: String, decision: AgentApprovalDecision)
            case answer(requestId: String, answers: [String: [String]])
            case resolvePlan(requestId: String, decision: AgentPlanDecision)
            case setRuntimeMode(AgentRuntimeMode)
            case setInteractionMode(AgentInteractionMode)
            case setModel(model: String?, effort: String?)
            case setRemoteControl(Bool)
            case revert(turnId: String)
            case dismissBanner
        }
    }

    struct ChatCommandResult: Codable, Sendable {
        /// A revert hands the reverted message back to the composer.
        var draft: String?
        var draftImages: [String]?

        static let none = ChatCommandResult()
    }

    /// Continue a chat in the agent's own TUI.
    struct OpenChatInTerminal: RPC {
        typealias Response = TerminalInfo?
        static let method = "chat.openInTerminal"
        var chatId: String
        var size: TerminalSize?
    }

    struct CheckpointDiff: RPC {
        typealias Response = [FileDiff]
        static let method = "chat.checkpointDiff"
        var cwd: String
        var from: String
        var to: String
    }

    // MARK: Settings

    struct SaveSettings: RPC {
        typealias Response = Empty
        static let method = "settings.save"
        var settings: AppSettings
    }

    // MARK: Files

    struct ListDirectory: RPC {
        typealias Response = [DirectoryEntry]
        static let method = "fs.list"
        /// `~` expands to the engine user's home.
        var path: String
    }

    struct ReadFile: RPC {
        typealias Response = Data?
        static let method = "fs.read"
        var path: String
        var maxBytes: Int
    }

    /// Put a file on the engine's machine (a pasted image, a dropped file)
    /// and return where it landed.
    struct UploadFile: RPC {
        typealias Response = String
        static let method = "fs.upload"
        var name: String
        var data: Data
    }
}

struct TerminalSize: Codable, Sendable, Equatable {
    var cols: UInt16
    var rows: UInt16
    var widthPx: UInt32 = 0
    var heightPx: UInt32 = 0
}

/// The tab a request opened: an agent chat or a terminal.
enum OpenedTab: Codable, Sendable {
    case chat(ChatSummary)
    case terminal(TerminalInfo)
}
