import Foundation

/// The Jetline client ↔ engine protocol.
///
/// Every Jetline app talks to an engine through this protocol — the
/// in-process one on the Mac (local mode) and `jetlined` on a remote host
/// alike — so both modes run the same code path. Requests are typed (`RPC`
/// types under `API`), the engine pushes state as `EngineEvent`s, and
/// terminal bytes ride their own binary frames (`FramedConnection`).
///
/// State model: the engine owns everything durable or process-backed
/// (repositories, worktrees, git, agents, terminals, the database). A
/// client mirrors it: `hello` returns a full snapshot, then events keep the
/// mirror current. Chat transcripts, which can be large, are only streamed
/// to clients that subscribe to them.
enum Wire {
    /// Bumped on any incompatible change. Client and engine must match.
    static let protocolVersion = 1

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    // MARK: Envelopes

    struct RequestHead: Decodable {
        var id: UInt64
        var method: String
    }

    struct Request<P: Encodable>: Encodable {
        var id: UInt64
        var method: String
        var params: P
    }

    struct RequestBody<P: Decodable>: Decodable {
        var params: P
    }

    struct ServerHead: Decodable {
        var type: String
        var id: UInt64?
    }

    struct Response<R: Encodable>: Encodable {
        var type = "response"
        var id: UInt64
        var result: R?
        var error: WireError?
    }

    struct ResponseBody<R: Decodable>: Decodable {
        var result: R?
        var error: WireError?
    }

    struct Event: Codable {
        var type = "event"
        var event: EngineEvent
    }
}

/// An RPC failure, carried back to the caller. `message` is user-facing.
struct WireError: Error, Codable, Sendable, LocalizedError, Equatable {
    var message: String
    var code: String?

    init(_ message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }

    var errorDescription: String? { message }

    static let disconnected = WireError("Not connected to the Jetline engine.", code: "disconnected")
}

/// A request the client can make. `Response` is what comes back.
protocol RPC: Codable, Sendable {
    associatedtype Response: Codable & Sendable
    static var method: String { get }
}

struct Empty: Codable, Sendable, Equatable {}

// MARK: - Snapshots

/// App-wide engine state, sent whole on every change (it is small).
struct GlobalSnapshot: Codable, Sendable, Equatable {
    var repositories: [Repository]
    var workspacesByRepo: [String: [Workspace]]
    var settings: AppSettings
    var repoMetadataByRepo: [String: RepoIdentifier]
    var prTrackerStatus: PRTrackerStatus
    var rateLimits: [AgentProviderKind: [AgentRateLimit]]
}

/// A workspace's diff state.
struct WorkspaceDiffState: Codable, Sendable, Equatable {
    var diff: DiffSnapshot?
    var localDiff: DiffSnapshot?
    var hasUncommitted: Bool
}

/// A workspace's live runtime: what's running there and what's in flight.
struct WorkspaceStatus: Codable, Sendable, Equatable {
    var branchPosition: BranchPosition
    var runningGitAction: GitAction?
    var isTogglingAutoMerge: Bool
    var isRefreshingPR: Bool
    /// Terminal tabs, in creation order.
    var terminals: [TerminalInfo]
    /// Open chat tabs, in creation order.
    var chats: [ChatSummary]
    var setup: ScriptRunInfo?
    var run: ScriptRunInfo?
    /// Whether the engine holds a live runtime (watcher, sessions) for it.
    var isOpen: Bool
}

struct TerminalInfo: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var workspaceId: String
    var agent: Workspace.AgentKind
    var cwd: String
    var hasStarted: Bool
    var lastError: String?
    var fellBackToShell: Bool
    /// Set once the process has exited.
    var exitCode: Int32?
}

/// What a tab strip needs to know about a chat without subscribing to its
/// transcript.
struct ChatSummary: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var provider: AgentProviderKind
    var title: String
    var activity: ChatActivity
}

/// A setup or run script's lifecycle, plus the terminal rendering it.
struct ScriptRunInfo: Codable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        case idle, queued, starting, running, finished
    }
    var phase: Phase
    var exitStatus: Int32?
    var terminalId: String?
}

/// Everything a new connection needs before events start flowing.
struct EngineSnapshot: Codable, Sendable {
    var global: GlobalSnapshot
    var diffs: [String: WorkspaceDiffState]
    var prs: [String: PRSnapshot]
    var conversations: [String: PRConversationSnapshot]
    var statuses: [String: WorkspaceStatus]
    var activity: [ActivityEvent]
}

// MARK: - Events

enum EngineEvent: Codable, Sendable {
    case global(GlobalSnapshot)
    case workspaceDiff(id: String, WorkspaceDiffState)
    case workspacePR(id: String, PRSnapshot)
    case workspaceConversation(id: String, PRConversationSnapshot)
    case workspaceStatus(id: String, WorkspaceStatus)
    /// The workspace's state was dropped (deleted, or its repo removed).
    case workspaceRemoved(id: String)
    /// Transcript change for a subscribed chat.
    case chat(id: String, ChatPatch)
    case activity(ActivityEvent)
    /// A chat finished a turn or started waiting on the user.
    case attention(chatId: String, workspaceId: String, critical: Bool)
    /// A long-running request failed after it was accepted (a fast-path git
    /// action that couldn't even fall back). User-facing.
    case error(String)
    /// The engine machine's listening ports changed (for clients that
    /// called `ports.watch`).
    case ports([ListeningPort])
}

// MARK: - Chat wire state

enum ChatConnection: Codable, Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

enum ChatActivity: String, Codable, Sendable, Equatable {
    case idle
    case working
    case needsInput
    case failed
}

enum ChatRemoteControl: Codable, Sendable, Equatable {
    case off
    case starting
    case on(URL?)
    case failed(String)
}

struct ChatQueuedMessage: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    var text: String
    /// Image paths on the engine's machine.
    var images: [String]
}

/// A chat's scalar state — everything but the transcript.
struct ChatMeta: Codable, Sendable, Equatable {
    var id: String
    var workspaceId: String
    var cwd: String
    var provider: AgentProviderKind
    var createdAt: Date
    var title: String
    var model: String?
    var effort: String?
    var resolvedModel: String?
    var runtimeMode: AgentRuntimeMode
    var interactionMode: AgentInteractionMode
    var connection: ChatConnection
    var remoteControl: ChatRemoteControl
    var requests: [AgentRequest]
    var todos: [AgentTodo]
    var usage: AgentTokenUsage?
    var models: [AgentModelOption]
    var commands: [AgentSlashCommand]
    var queued: [ChatQueuedMessage]
    var banner: String?
    var isReverting: Bool
    var canRevert: Bool
    var terminalResumeArgs: [String]?
}

struct ChatTurnMeta: Codable, Sendable, Equatable {
    var id: String
    var seq: Int
    var providerTurnId: String?
    var status: String
    var errorMessage: String?
    var startedAt: Date
    var completedAt: Date?
    var checkpointBefore: String?
    var checkpointAfter: String?
    var stat: Checkpointer.Stat?
    /// Box ids, in timeline order.
    var itemIds: [String]
}

struct ChatItemWire: Codable, Sendable, Equatable {
    var boxId: String
    var item: AgentItem
    var createdAt: Date?
}

enum ChatItemChange: Codable, Sendable {
    case upsert(ChatItemWire)
    /// Streamed text appended to an item's growing field — sent instead of
    /// the whole item so a long answer doesn't re-ship its full text on
    /// every flush.
    case append(boxId: String, kind: AgentStreamKind, text: String)
}

/// One step of a chat's transcript sync. A `full` patch replaces the
/// mirror; otherwise only what changed since the previous patch is present.
struct ChatPatch: Codable, Sendable {
    var full: Bool
    var meta: ChatMeta?
    /// Turn ids in order, when the set or order of turns changed.
    var turnOrder: [String]?
    var turns: [ChatTurnMeta]
    var items: [ChatItemChange]
}

/// What a remote directory browser shows.
struct DirectoryEntry: Codable, Sendable, Equatable, Identifiable {
    var name: String
    var path: String
    var isDirectory: Bool
    var isGitRepo: Bool
    var id: String { path }
}
