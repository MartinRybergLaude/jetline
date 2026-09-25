import Foundation

// The provider-neutral conversation model. Claude Code's stream-json control
// protocol and Codex's app-server JSON-RPC are both translated into these
// types by their mappers; everything downstream (the chat session reducer,
// persistence, the timeline UI) only ever sees this vocabulary.
//
// The shape follows T3 Code's runtime model, trimmed to what the two agents
// actually share: turns that contain items, items that stream text, and
// requests that pause a turn until the user answers.

/// Which agent CLI backs a chat.
enum AgentProviderKind: String, Codable, Sendable, CaseIterable, Hashable {
    case claude
    case codex

    var agentKind: Workspace.AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    init?(agent: Workspace.AgentKind) {
        switch agent {
        case .claude: self = .claude
        case .codex: self = .codex
        case .vibe, .shell: return nil
        }
    }

    var displayName: String { agentKind.displayName }
}

/// How much the agent may do before it has to ask. Each provider maps
/// these onto its own permission vocabulary (see the providers).
enum AgentRuntimeMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Ask before editing files or running commands.
    case supervised
    /// File edits go through; commands still ask.
    case acceptEdits
    /// The agent's own reviewer (Claude's auto mode classifier, Codex's
    /// auto-review subagent) decides, escalating only the risky calls.
    case auto
    /// Never ask.
    case fullAccess

    var displayName: String {
        switch self {
        case .supervised: return "Supervised"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto"
        case .fullAccess: return "Full access"
        }
    }

    var summary: String {
        switch self {
        case .supervised: return "Ask before edits and commands"
        case .acceptEdits: return "Edit files freely, ask before commands"
        case .auto: return "Let the agent's reviewer approve safe actions"
        case .fullAccess: return "Never ask for approval"
        }
    }

    var symbol: String {
        switch self {
        case .supervised: return "hand.raised"
        case .acceptEdits: return "pencil"
        case .auto: return "wand.and.stars"
        case .fullAccess: return "bolt"
        }
    }
}

/// Plan mode: the agent researches and proposes instead of changing files.
enum AgentInteractionMode: String, Codable, Sendable, Hashable {
    case normal
    case plan
}

// MARK: - Session configuration

/// Everything a provider needs to start (or resume) its process.
struct AgentSessionConfig: Sendable {
    var cwd: String
    var executable: String
    var model: String?
    var effort: String?
    var runtimeMode: AgentRuntimeMode
    var interactionMode: AgentInteractionMode
    /// Opaque provider state from a previous run (see `AgentResumeCursor`).
    var resume: AgentResumeCursor?
}

/// Provider-specific identity of a conversation, persisted so a chat can be
/// resumed after its process exits or the app relaunches. Kept as a small
/// struct rather than opaque JSON so both providers' needs are visible in
/// one place.
struct AgentResumeCursor: Codable, Sendable, Hashable {
    /// Claude: the session id (`--session-id` / `--resume`). Codex: the
    /// thread id (`thread/start` / `thread/resume`).
    var sessionId: String
    /// Claude only: every turn, oldest first, with the last transcript
    /// message it produced. Reverting to before turn N resumes the session
    /// cut at turn N-1's last message.
    var turns: [TurnAnchor] = []

    struct TurnAnchor: Codable, Sendable, Hashable {
        var turnId: String
        /// nil until the turn writes a message; a turn that never did
        /// inherits its predecessor's cut point.
        var lastMessageId: String?
    }

    init(sessionId: String, turns: [TurnAnchor] = []) {
        self.sessionId = sessionId
        self.turns = turns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        turns = try container.decodeIfPresent([TurnAnchor].self, forKey: .turns) ?? []
    }
}

/// What a running session reports about itself once it's up.
struct AgentSessionInfo: Sendable, Equatable {
    var resume: AgentResumeCursor
    var model: String?
    var models: [AgentModelOption]
    var commands: [AgentSlashCommand]
    var cliVersion: String?
}

struct AgentModelOption: Codable, Sendable, Hashable, Identifiable {
    /// Value passed back to the CLI to select this model.
    var id: String
    var displayName: String
    var description: String?
    var efforts: [String]
    var defaultEffort: String?
    var isDefault: Bool
}

struct AgentSlashCommand: Sendable, Hashable, Identifiable {
    var name: String
    var description: String
    var argumentHint: String?
    var id: String { name }
}

struct AgentCapabilities: Sendable, Hashable {
    /// Model can be switched on a live session without a restart.
    var liveModelSwitch: Bool
    /// Messages sent during a running turn are delivered to it.
    var steering: Bool
    /// The conversation can be truncated back to before a turn.
    var conversationRevert: Bool
    /// The conversation can be continued from claude.ai or the Claude
    /// mobile app while it runs here.
    var remoteControl: Bool = false
}

/// Remote Control's link to claude.ai, as the provider reports it.
enum AgentRemoteControlStatus: Sendable, Equatable {
    /// Turned back on by the provider itself (after a respawn), under a
    /// new link.
    case restarted(URL?)
    case failed(String)
}

// MARK: - Turn input

struct AgentTurnInput: Sendable {
    var text: String
    /// Local image files to attach.
    var images: [URL] = []
    var model: String?
    var effort: String?
    var interactionMode: AgentInteractionMode = .normal
}

// MARK: - Items

/// One entry of a turn: a message, a tool call, a file change. Providers
/// emit full snapshots of an item as it progresses, plus text deltas in
/// between, so the reducer never has to understand provider semantics.
struct AgentItem: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var turnId: String?
    /// Tool call id of the subagent this item ran inside, if any.
    var parentId: String?
    var status: Status
    var content: Content

    enum Status: String, Codable, Sendable {
        case inProgress
        case completed
        case failed
        case declined
        case interrupted

        var isTerminal: Bool { self != .inProgress }
    }

    enum Content: Codable, Sendable, Equatable {
        case userMessage(UserMessage)
        case assistantMessage(text: String)
        case reasoning(text: String)
        case command(Command)
        case fileChange(FileChange)
        case tool(ToolCall)
        case webSearch(query: String)
        case subagent(Subagent)
        /// Plan-mode proposal, rendered as a plan card.
        case plan(text: String)
        case compaction
        case notice(Notice)
    }

    struct UserMessage: Codable, Sendable, Equatable {
        var text: String
        var images: [String] = []
    }

    struct Command: Codable, Sendable, Equatable {
        var command: String
        var cwd: String?
        var output: String = ""
        var exitCode: Int?
        var durationMs: Int?
        /// Short human label when the agent gave one (Claude's Bash
        /// `description`).
        var summary: String?
    }

    struct FileChange: Codable, Sendable, Equatable {
        var edits: [FileEdit]
    }

    struct FileEdit: Codable, Sendable, Equatable {
        enum Kind: String, Codable, Sendable { case add, delete, update, move }
        var path: String
        var kind: Kind
        /// Unified diff of this file's change, when the provider reports one.
        var diff: String?
        var movedTo: String?
    }

    struct ToolCall: Codable, Sendable, Equatable {
        var name: String
        /// MCP server for MCP tools.
        var server: String?
        var input: JSONValue?
        var output: String?
        /// One-line description of what the call does ("Read AppState.swift").
        var summary: String?
    }

    struct Subagent: Codable, Sendable, Equatable {
        var description: String
        var prompt: String?
        var agentType: String?
        var result: String?
        /// Runs on after its tool call returns, and past the turn that
        /// started it; the item stays in progress until it reports back.
        var runsInBackground: Bool?
    }

    struct Notice: Codable, Sendable, Equatable {
        enum Level: String, Codable, Sendable { case info, warning, error }
        var level: Level
        var text: String
    }

    /// Append streamed text to whichever field the stream kind targets.
    mutating func append(_ delta: String, kind: AgentStreamKind) {
        switch (kind, content) {
        case (.assistantText, .assistantMessage(let text)):
            content = .assistantMessage(text: text + delta)
        case (.reasoningText, .reasoning(let text)):
            content = .reasoning(text: text + delta)
        case (.planText, .plan(let text)):
            content = .plan(text: text + delta)
        case (.commandOutput, .command(var command)):
            command.output += delta
            content = .command(command)
        case (.toolOutput, .tool(var tool)):
            tool.output = (tool.output ?? "") + delta
            content = .tool(tool)
        default:
            break
        }
    }

    static func notice(
        _ level: Notice.Level, _ text: String, turnId: String?, id: String = "notice-\(UUID().uuidString)"
    ) -> AgentItem {
        AgentItem(id: id, turnId: turnId, status: .completed, content: .notice(.init(level: level, text: text)))
    }

    /// Placeholder content for a delta that arrives before its item.
    static func placeholder(id: String, turnId: String?, kind: AgentStreamKind) -> AgentItem? {
        let content: Content
        switch kind {
        case .assistantText: content = .assistantMessage(text: "")
        case .reasoningText: content = .reasoning(text: "")
        case .planText: content = .plan(text: "")
        case .commandOutput, .toolOutput: return nil
        }
        return AgentItem(id: id, turnId: turnId, status: .inProgress, content: content)
    }
}

enum AgentStreamKind: String, Codable, Sendable {
    case assistantText
    case reasoningText
    case planText
    case commandOutput
    case toolOutput
}

/// One step of the agent's working checklist (Claude's TodoWrite, Codex's
/// `turn/plan/updated`).
struct AgentTodo: Codable, Sendable, Hashable {
    enum Status: String, Codable, Sendable {
        case pending, inProgress, completed

        /// Either CLI's wire value; anything unknown reads as pending.
        init(wire: String?) {
            switch wire {
            case "completed": self = .completed
            case "inProgress", "in_progress": self = .inProgress
            default: self = .pending
            }
        }
    }
    var text: String
    var status: Status
}

struct AgentTokenUsage: Codable, Sendable, Equatable {
    /// Tokens currently occupying the context window.
    var contextTokens: Int
    var contextWindow: Int?
}

/// One usage window of the account's plan: Claude's 5-hour and weekly
/// limits, Codex's primary and secondary ones.
struct AgentRateLimit: Sendable, Equatable, Identifiable {
    /// The window's key ("five_hour", "seven_day", "primary", ...).
    var id: String
    var name: String
    /// Share of the window used, 0–1.
    var used: Double
    var resetsAt: Date?

    /// "5-hour limit" or "Weekly limit" for a window of this many minutes.
    static func name(minutes: Int) -> String {
        switch minutes {
        case 300: return "5-hour limit"
        case 10_080: return "Weekly limit"
        case let m where m % 1_440 == 0: return "\(m / 1_440)-day limit"
        case let m where m % 60 == 0: return "\(m / 60)-hour limit"
        default: return "\(minutes)-minute limit"
        }
    }
}

// MARK: - Requests

/// Something that blocks the agent until the user answers.
struct AgentRequest: Sendable, Identifiable, Equatable {
    var id: String
    var turnId: String?
    var itemId: String?
    var kind: Kind

    enum Kind: Sendable, Equatable {
        case approval(AgentApproval)
        case questions([AgentQuestion])
        /// Plan mode finished: approve to leave plan mode and implement.
        case plan(text: String)
    }
}

struct AgentApproval: Sendable, Equatable {
    enum Category: String, Sendable {
        case command
        case fileChange
        case fileRead
        case network
        case tool
        case permissions
    }

    var category: Category
    var title: String
    /// The command, path or tool input the user is approving.
    var detail: String?
    var reason: String?
    /// Whether "allow for the rest of this session" is on offer.
    var allowsSessionScope: Bool
}

enum AgentApprovalDecision: Sendable, Equatable {
    case allowOnce
    case allowForSession
    case deny(message: String?)
    /// Abort the whole turn, not just this call.
    case cancel
}

struct AgentQuestion: Sendable, Equatable, Identifiable {
    struct Option: Sendable, Equatable, Hashable {
        var label: String
        var description: String?
    }

    var id: String
    var header: String?
    var prompt: String
    var options: [Option]
    var allowsMultiple: Bool
    var allowsFreeform: Bool
}

/// Answer to a plan approval request.
enum AgentPlanDecision: Sendable, Equatable {
    /// Leave plan mode (switching to `mode`) and let the agent implement.
    case implement(mode: AgentRuntimeMode)
    case keepPlanning(feedback: String?)
}

// MARK: - Events

enum AgentTurnOutcome: Sendable, Equatable {
    case completed
    case interrupted
    case failed(message: String)
}

struct AgentExit: Sendable, Equatable {
    var status: Int32
    /// Tail of the process's stderr, for the error shown in the chat.
    var stderr: String
    /// True when Jetline asked the process to stop.
    var expected: Bool
}

/// What a provider reports. A chat session folds these into its state.
enum AgentEvent: Sendable, Equatable {
    case ready(AgentSessionInfo)
    case turnStarted(id: String)
    case turnCompleted(id: String, AgentTurnOutcome)
    /// Insert or replace an item with this snapshot.
    case item(AgentItem)
    case delta(itemId: String, turnId: String?, kind: AgentStreamKind, text: String)
    case requestOpened(AgentRequest)
    case requestClosed(id: String)
    case todos([AgentTodo])
    case usage(AgentTokenUsage)
    /// Windows to merge into the known ones, by id.
    case rateLimits([AgentRateLimit])
    /// The agent's permission mode changed underneath us (an approval that
    /// carried "allow all edits", leaving plan mode, ...).
    case runtimeModeChanged(AgentRuntimeMode)
    case interactionModeChanged(AgentInteractionMode)
    case modelChanged(String)
    /// New resume state to persist (after a turn, a revert, a fork).
    case resumeUpdated(AgentResumeCursor)
    case remoteControl(AgentRemoteControlStatus)
    case exited(AgentExit)
}

enum AgentError: LocalizedError, Equatable {
    case executableNotFound(String)
    case notRunning
    case launchFailed(String)
    case protocolError(String)
    case requestFailed(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(name):
            return "Couldn't find `\(name)`. Set its path in Settings → Agents."
        case .notRunning:
            return "The agent isn't running."
        case let .launchFailed(message):
            return "Couldn't start the agent: \(message)"
        case let .protocolError(message):
            return "Unexpected response from the agent: \(message)"
        case let .requestFailed(message):
            return message
        case let .unsupported(message):
            return message
        }
    }
}
