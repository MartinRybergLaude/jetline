import Foundation

/// The session tools: an agent starts chats in the workspaces it created,
/// sends them follow-ups, and reads what any session in Jetline has done.
///
/// Answering a session's approvals and questions stays with the user: an
/// agent that could approve another's tool calls would hold every
/// permission there is. And only a session the user started may start or
/// message others, so agents can't fan out without bound.
extension AgentTools {
    static let sessionCatalog: [Tool] = [
        Tool(
            name: "list_sessions",
            description: """
            The chats and terminals open in a workspace, or without workspace_id in every \
            workspace in Jetline: id, workspace, kind, agent, title, status (working, idle, \
            needs_input, failed; a terminal is running or exited) and whether you created its \
            workspace.
            """,
            inputSchema: schema(["workspace_id": .object([
                "type": "string",
                "description": "A workspace id from list_workspaces. Omit for every workspace."
            ])]),
            readOnly: true
        ),
        Tool(
            name: "read_session",
            description: """
            What a session has done. For a chat: its latest turns (the prompt, the agent's \
            final reply, files changed, errors) and anything waiting on the user. For a \
            terminal: the end of its output.
            """,
            inputSchema: schema([
                "session_id": sessionIdProperty,
                "turns": .object([
                    "type": "integer",
                    "description": .string("How many of the latest turns to return (default \(defaultReadTurns), at most \(maxReadTurns)).")
                ])
            ], required: ["session_id"]),
            readOnly: true
        ),
        Tool(
            name: "wait_for_sessions",
            description: """
            Wait until any of the given chats stops working (finished, needs the user, or \
            failed), or until the timeout. Says which are ready and which still work; call \
            again to keep waiting. A terminal counts as ready once its process exits.
            """,
            inputSchema: schema([
                "session_ids": .object(["type": "array", "items": .object(["type": "string"])]),
                "timeout_seconds": .object([
                    "type": "integer",
                    "description": .string("Default \(defaultWaitSeconds), at most \(maxWaitSeconds).")
                ])
            ], required: ["session_ids"]),
            readOnly: true
        ),
        Tool(
            name: "start_session",
            description: """
            Start an agent chat in a workspace you created and send it prompt as its first \
            message. It shows as a tab in the user's sidebar. The agent runs on its own; its \
            approvals and questions go to the user, not to you. Write the prompt as a complete \
            brief: it knows nothing of your conversation.
            """,
            inputSchema: schema([
                "workspace_id": .object(["type": "string", "description": "A workspace you created with create_workspace or import_branch."]),
                "prompt": .object(["type": "string"]),
                "provider": .object([
                    "type": "string",
                    "enum": .array(AgentProviderKind.allCases.map { .string($0.rawValue) }),
                    "description": "Defaults to the workspace's agent, else claude."
                ])
            ], required: ["workspace_id", "prompt"]),
            readOnly: false
        ),
        Tool(
            name: "send_message",
            description: """
            Send the same message to one or more chats, e.g. instructions that apply to every \
            session you dispatched. Any open chat outside your own workspace can be messaged, \
            including ones the user started. A working chat gets it steered into the running \
            turn, or after that turn finishes.
            """,
            inputSchema: schema([
                "session_ids": .object(["type": "array", "items": .object(["type": "string"])]),
                "text": .object(["type": "string"])
            ], required: ["session_ids", "text"]),
            readOnly: false
        )
    ]

    static let defaultReadTurns = 3
    static let maxReadTurns = 20
    static let defaultWaitSeconds = 120
    static let maxWaitSeconds = 600
    /// Longer texts in a session report are cut to this many characters.
    static let maxReportedText = 4_000
    static let reportedTerminalTail = 8_000

    private static let sessionIdProperty: JSONValue = .object([
        "type": "string",
        "description": "A session id from list_sessions or start_session."
    ])
}

// MARK: - Engine side

extension Engine {
    /// Run one of `AgentTools.sessionCatalog` for an agent in `caller`.
    func runSessionTool(_ tool: String, _ args: AgentToolArguments, caller: Workspace) async throws -> [String: JSONValue] {
        switch tool {
        case "list_sessions":
            let workspaces = try args.string("workspace_id").map { [try workspace(id: $0)] } ?? allWorkspaces
            return ["sessions": .array(workspaces.flatMap { sessionSummaries(in: $0, caller: caller) })]
        case "read_session":
            let turns = min(max(args.int("turns") ?? AgentTools.defaultReadTurns, 1), AgentTools.maxReadTurns)
            switch try session(args.requiredString("session_id")) {
            case let .chat(chat): return AgentSessionReport.chat(chat, turns: turns)
            case let .terminal(terminal): return AgentSessionReport.terminal(terminal)
            }
        case "wait_for_sessions":
            return try await waitForSessions(args)
        case "start_session":
            return try startSession(args, caller: caller)
        case "send_message":
            return try sendMessage(args, caller: caller)
        default:
            throw WireError("Unknown tool \(tool).")
        }
    }

    private enum Session {
        case chat(ChatEngine)
        case terminal(EngineTerminal)

        @MainActor var isBusy: Bool {
            switch self {
            case let .chat(chat): return chat.activity == .working
            case let .terminal(terminal): return !terminal.hasStarted || terminal.isRunning
            }
        }

        @MainActor var status: String {
            switch self {
            case let .chat(chat): return AgentSessionReport.status(chat.activity)
            case let .terminal(terminal): return AgentSessionReport.status(terminal)
            }
        }
    }

    /// Every workspace, each repository's own checkout included.
    private var allWorkspaces: [Workspace] {
        repositories.flatMap { repo in
            let checkout = workspaceById(repositoryBaseWorkspaceId(for: repo)).map { [$0] } ?? []
            return checkout + (workspacesByRepo[repo.id] ?? [])
        }
    }

    private func session(_ id: String) throws -> Session {
        if let chat = chat(id: id) { return .chat(chat) }
        if let terminal = terminal(id: id) { return .terminal(terminal) }
        throw WireError("No open session \(id). list_sessions shows the ids.")
    }

    private func sessionSummaries(in ws: Workspace, caller: Workspace) -> [JSONValue] {
        let state = workspaceState(for: ws.id)
        let chats = state.chats.map { AgentSessionReport.summary(of: $0, workspace: ws) }
        let terminals = state.terminals.map { AgentSessionReport.summary(of: $0, workspace: ws) }
        let createdByCaller = JSONValue.bool(ws.createdByWorkspaceId == caller.id)
        return (chats + terminals).map { .object($0.merging(["you_created_workspace": createdByCaller]) { _, new in new }) }
    }

    /// Every chat is checked before any is sent to, so a bad id sends nothing.
    private func sendMessage(_ args: AgentToolArguments, caller: Workspace) throws -> [String: JSONValue] {
        try requireUserStarted(caller, to: "message")
        let ids = args.strings("session_ids")
        guard !ids.isEmpty else { throw WireError("session_ids is required.") }
        let text = try args.requiredString("text")
        let chats = try ids.map { try messageableChat($0, caller: caller) }
        for chat in chats { chat.send(text: text) }
        return ["sent": .array(chats.map { chat in
            .object(["session_id": .string(chat.id), "status": .string(AgentSessionReport.status(chat.activity))])
        })]
    }

    /// Any chat outside the caller's workspace: inside it, the caller would
    /// be messaging itself or the chat it shares the worktree with.
    private func messageableChat(_ id: String, caller: Workspace) throws -> ChatEngine {
        guard case let .chat(chat) = try session(id) else {
            throw WireError("\(id) is a terminal; send_message only writes to chats.")
        }
        guard chat.workspaceId != caller.id else {
            throw WireError("\(id) is in your own workspace; message chats in other workspaces.")
        }
        return chat
    }

    /// Agents an agent started may not start or message others, so sessions
    /// can't fan out without bound.
    private func requireUserStarted(_ caller: Workspace, to action: String) throws {
        guard caller.createdByWorkspaceId == nil else {
            throw WireError("Only sessions the user started may \(action) other sessions; this workspace was created by an agent.")
        }
    }

    private func startSession(_ args: AgentToolArguments, caller: Workspace) throws -> [String: JSONValue] {
        try requireUserStarted(caller, to: "start")
        let target = try workspace(id: args.requiredString("workspace_id"))
        guard target.createdByWorkspaceId == caller.id else {
            throw WireError("You may only start sessions in workspaces you created. \(target.name) isn't one; create_workspace makes one.")
        }
        let provider = try args.string("provider").map { name in
            guard let kind = AgentProviderKind(rawValue: name) else { throw WireError("Unknown provider \(name).") }
            return kind
        } ?? AgentProviderKind(agent: target.agent) ?? .claude
        let chat = startNewChat(for: target, provider: provider, prompt: try args.requiredString("prompt"))
        return [
            "session_id": .string(chat.id),
            "workspace_id": .string(target.id),
            "provider": .string(provider.rawValue),
            "status": .string(AgentSessionReport.status(chat.activity)),
            "setup_script_running": .bool(workspaceState(for: target.id).setup?.isRunning ?? false)
        ]
    }

    private func waitForSessions(_ args: AgentToolArguments) async throws -> [String: JSONValue] {
        let ids = args.strings("session_ids")
        guard !ids.isEmpty else { throw WireError("session_ids is required.") }
        let seconds = min(max(args.int("timeout_seconds") ?? AgentTools.defaultWaitSeconds, 1), AgentTools.maxWaitSeconds)
        let deadline = ContinuousClock.now + .seconds(seconds)
        var sessions = try ids.map { ($0, try session($0)) }
        while sessions.allSatisfy({ $0.1.isBusy }), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            // A session closed meanwhile is gone, not busy.
            sessions = sessions.compactMap { id, _ in (try? session(id)).map { (id, $0) } }
        }
        let closed = ids.filter { id in !sessions.contains { $0.0 == id } }
        let entries: (Bool) -> JSONValue = { busy in
            .array(sessions.filter { $0.1.isBusy == busy }.map { id, session in
                .object(["session_id": .string(id), "status": .string(session.status)])
            })
        }
        return [
            "ready": entries(false),
            "still_working": entries(true),
            "closed": .array(closed.map(JSONValue.string)),
            "timed_out": .bool(sessions.allSatisfy { $0.1.isBusy } && closed.isEmpty)
        ]
    }
}

/// How sessions read to an agent: plain JSON, long texts cut short.
@MainActor
enum AgentSessionReport {
    static func status(_ activity: ChatActivity) -> String {
        switch activity {
        case .idle: return "idle"
        case .working: return "working"
        case .needsInput: return "needs_input"
        case .failed: return "failed"
        }
    }

    static func status(_ terminal: EngineTerminal) -> String {
        if terminal.exitCode != nil { return "exited" }
        return terminal.hasStarted ? "running" : "starting"
    }

    static func summary(of chat: ChatEngine, workspace: Workspace) -> [String: JSONValue] {
        [
            "session_id": .string(chat.id),
            "workspace_id": .string(workspace.id),
            "workspace": .string(workspace.name),
            "kind": "chat",
            "agent": .string(chat.provider.rawValue),
            "title": .string(chat.title),
            "status": .string(status(chat.activity)),
            "turns": .int(Int64(chat.turns.count))
        ]
    }

    static func summary(of terminal: EngineTerminal, workspace: Workspace) -> [String: JSONValue] {
        [
            "session_id": .string(terminal.id),
            "workspace_id": .string(workspace.id),
            "workspace": .string(workspace.name),
            "kind": "terminal",
            "agent": .string(terminal.agent.rawValue),
            "status": .string(status(terminal)),
            "exit_code": terminal.exitCode.map { .int(Int64($0)) } ?? .null
        ]
    }

    static func chat(_ chat: ChatEngine, turns count: Int) -> [String: JSONValue] {
        let shown = chat.turns.suffix(count)
        return [
            "session_id": .string(chat.id),
            "kind": "chat",
            "title": .string(chat.title),
            "status": .string(status(chat.activity)),
            "waiting_on_user": .array(chat.requests.map(request)),
            "queued_messages": .int(Int64(chat.queued.count)),
            "earlier_turns": .int(Int64(chat.turns.count - shown.count)),
            "turns": .array(shown.map { .object(turn($0)) })
        ]
    }

    static func terminal(_ terminal: EngineTerminal) -> [String: JSONValue] {
        [
            "session_id": .string(terminal.id),
            "kind": "terminal",
            "status": .string(status(terminal)),
            "exit_code": terminal.exitCode.map { .int(Int64($0)) } ?? .null,
            "output_tail": .string(tail(terminal.plainText(), maxLength: AgentTools.reportedTerminalTail))
        ]
    }

    /// One turn: the prompt, the agent's last top-level reply, and what it
    /// touched. Subagents' own messages are left out.
    static func turn(_ turn: ChatTurn) -> [String: JSONValue] {
        let items = turn.items.map(\.item).filter { $0.parentId == nil }
        let reply = items.reversed().lazy.compactMap { item -> String? in
            if case let .assistantMessage(text) = item.content { return text.nonBlank }
            return nil
        }.first
        var files: [String] = []
        var commands = 0
        var failedCommands: [JSONValue] = []
        for item in items {
            switch item.content {
            case let .fileChange(change):
                for path in change.edits.map(\.path) where !files.contains(path) { files.append(path) }
            case let .command(command):
                commands += 1
                if item.status == .failed || (command.exitCode ?? 0) != 0 {
                    failedCommands.append(.string(head(command.command, maxLength: 200)))
                }
            default:
                break
            }
        }
        return [
            "turn": .int(Int64(turn.seq)),
            "status": .string(turn.status.rawValue),
            "prompt": turn.userMessage.map { .string(head($0.text, maxLength: AgentTools.maxReportedText)) } ?? .null,
            "reply": reply.map { .string(head($0, maxLength: AgentTools.maxReportedText)) } ?? .null,
            "files_changed": .array(files.map(JSONValue.string)),
            "commands_run": .int(Int64(commands)),
            "failed_commands": .array(failedCommands),
            "error": turn.errorMessage.map(JSONValue.string) ?? .null
        ]
    }

    static func request(_ request: AgentRequest) -> JSONValue {
        switch request.kind {
        case let .approval(approval):
            return [
                "kind": "approval",
                "title": .string(approval.title),
                "detail": approval.detail.map { .string(head($0, maxLength: 500)) } ?? .null
            ]
        case let .questions(questions):
            return ["kind": "questions", "questions": .array(questions.map { .string($0.prompt) })]
        case let .plan(text):
            return ["kind": "plan", "plan": .string(head(text, maxLength: AgentTools.maxReportedText))]
        }
    }

    static func head(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "… [\(text.count - maxLength) more characters]"
    }

    static func tail(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return "[\(text.count - maxLength) earlier characters] …" + String(text.suffix(maxLength))
    }
}
