import Foundation

/// Drives Claude Code through its stream-json control protocol — the same
/// channel the official Agent SDKs use:
///
///     claude --input-format stream-json --output-format stream-json
///            --permission-prompt-tool stdio ...
///
/// User messages and `control_request`s (initialize, interrupt,
/// set_permission_mode, set_model) go in on stdin. SDK messages come out on
/// stdout, along with `control_request`s from the CLI — `can_use_tool` is
/// how every permission prompt, `AskUserQuestion` and `ExitPlanMode`
/// reaches us — which we answer with `control_response`s.
///
/// The protocol is SDK-internal rather than documented CLI surface; the
/// Python SDK (`claude_agent_sdk/_internal/query.py`) is the reference.
actor ClaudeProvider: AgentProvider {
    nonisolated let kind: AgentProviderKind = .claude
    nonisolated let capabilities = AgentCapabilities(
        liveModelSwitch: true,
        // Messages sent mid-turn are queued by the CLI and answered as
        // separate turns, not folded into the running one.
        steering: false,
        conversationRevert: true,
        remoteControl: true
    )
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation

    private var config: AgentSessionConfig?
    private var process: JSONLineProcess?
    private var readerTask: Task<Void, Never>?
    private var mapper = ClaudeEventMapper()
    private var sessionId: String?
    /// Last transcript message per turn, for revert (see
    /// `AgentResumeCursor.turns`).
    private var anchors: [AgentResumeCursor.TurnAnchor] = []

    private var pendingControl = PendingReplies<String>()
    private var permissionRequests: [String: PermissionRequest] = [:]
    private var requestCounter = 0

    private var activeTurnId: String?
    private var runtimeMode: AgentRuntimeMode = .supervised
    private var interactionMode: AgentInteractionMode = .normal
    private var stopping = false
    /// Set when an interrupt had to kill the process: the next message
    /// respawns it with `--resume`.
    private var needsRespawn = false
    /// Uuids of the messages we sent, whose replay echoes we already show.
    private var sentMessageIds: Set<String> = []
    /// Remote Control's session name while it's on; restored on respawn.
    private var remoteControlName: String??

    private struct PermissionRequest {
        var toolName: String
        var toolUseId: String?
        var input: JSONValue
        var suggestions: [JSONValue]
    }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: AgentEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    func start(_ config: AgentSessionConfig) async throws {
        self.config = config
        runtimeMode = config.runtimeMode
        interactionMode = config.interactionMode
        if let resume = config.resume {
            sessionId = resume.sessionId
            anchors = resume.turns
            do {
                try await spawn(resume: true)
                return
            } catch {
                // The transcript is gone (deleted, or never written because
                // the first turn didn't complete). Start over rather than
                // leaving the chat unusable.
                emitNotice(.warning, "Couldn't resume the previous Claude session, so a new one was started.")
            }
        }
        sessionId = UUID().uuidString.lowercased()
        anchors = []
        try await spawn(resume: false)
    }

    /// `fork`: resume `sessionId` truncated after message `at`, under the
    /// new id `forkAs`.
    private struct Fork {
        var at: String
        var forkAs: String
    }

    private func spawn(resume: Bool, fork: Fork? = nil) async throws {
        guard let config, let sessionId else { throw AgentError.notRunning }
        var args = [
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--permission-prompt-tool", "stdio",
            "--permission-mode", Self.claudeMode(for: runtimeMode, interaction: interactionMode),
            // Lets `set_permission_mode` switch to bypassPermissions later
            // without it being the starting mode.
            "--allow-dangerously-skip-permissions",
            "--thinking-display", "summarized",
            // Echoes every user message as it starts, so messages sent from
            // claude.ai over Remote Control show up here too.
            "--replay-user-messages"
        ]
        if let model = config.model { args += ["--model", model] }
        if let effort = config.effort { args += ["--effort", effort] }
        if let fork {
            args += ["--resume", sessionId, "--resume-session-at", fork.at, "--fork-session", "--session-id", fork.forkAs]
        } else {
            args += resume ? ["--resume", sessionId] : ["--session-id", sessionId]
        }

        _ = await LoginShellPath.get()
        var env = Subprocess.inheritedEnvironment(overrides: ["JETLINE": "1"])
        // Jetline launched from inside a Claude Code terminal inherits this,
        // and the CLI treats it as "you are a nested session".
        env.removeValue(forKey: "CLAUDECODE")

        let process = JSONLineProcess(.init(
            executable: config.executable, args: args, cwd: config.cwd, env: env
        ))
        try process.start()
        self.process = process
        stopping = false
        needsRespawn = false
        startReading(process)

        let response: JSONValue
        do {
            response = try await control(["subtype": "initialize", "hooks": nil], timeout: .seconds(60))
        } catch {
            // Detach first so `processEnded` doesn't treat this as the
            // session dying and finish the event stream.
            self.process = nil
            await process.terminate(grace: .milliseconds(200))
            let stderr = process.stderrTail.nonBlank
            throw AgentError.launchFailed(stderr ?? error.localizedDescription)
        }
        if let fork { self.sessionId = fork.forkAs }
        continuation.yield(.ready(sessionInfo(from: response)))
        if let name = remoteControlName {
            do {
                continuation.yield(.remoteControl(.restarted(try await enableRemoteControl(name: name))))
            } catch {
                remoteControlName = nil
                continuation.yield(.remoteControl(.failed(error.localizedDescription)))
            }
        }
    }

    func stop() async {
        stopping = true
        if let process {
            await process.terminate()
        }
    }

    // MARK: - Reading

    private func startReading(_ process: JSONLineProcess) {
        readerTask = Task { [weak self] in
            for await line in process.lines {
                await self?.handle(line: line)
            }
            let status = await process.waitForExit()
            await self?.processEnded(process, status: status)
        }
    }

    private func handle(line: Data) {
        guard let message = try? JSONValue.parse(line) else { return }
        switch message["type"]?.string {
        case "control_response":
            handleControlResponse(message["response"] ?? .null)
        case "control_request":
            handleControlRequest(message)
        case "control_cancel_request":
            if let id = message["request_id"]?.string, permissionRequests.removeValue(forKey: id) != nil {
                continuation.yield(.requestClosed(id: id))
            }
        case "user" where message["isReplay"]?.bool == true:
            handleReplay(message)
        case "system" where message["subtype"]?.string == "bridge_state":
            handleBridgeState(message)
        default:
            openSyntheticTurnIfNeeded(for: message)
            let turnId = mapper.turnId
            let events = mapper.map(message)
            recordAnchor(message, turnId: turnId)
            for event in events {
                continuation.yield(event)
                if case let .turnCompleted(id, _) = event, id == activeTurnId {
                    activeTurnId = nil
                    closeAllRequests()
                    continuation.yield(.resumeUpdated(currentCursor))
                }
            }
        }
    }

    /// Claude can speak between turns: a background task or agent finishes
    /// and the CLI starts a turn of its own. Give that output a turn so it
    /// doesn't land loose; its `result` closes it. (T3 Code, issue #9698.)
    private func openSyntheticTurnIfNeeded(for message: JSONValue) {
        guard activeTurnId == nil,
              message["parent_tool_use_id"]?.string == nil,
              ["assistant", "stream_event", "user"].contains(message["type"]?.string ?? "") else { return }
        let turnId = UUID().uuidString.lowercased()
        activeTurnId = turnId
        mapper.turnId = turnId
        anchors.append(.init(turnId: turnId, lastMessageId: anchors.last?.lastMessageId))
        continuation.yield(.turnStarted(id: turnId))
    }

    /// A user message starting. Ours are on screen already; any other came
    /// in over Remote Control and starts a turn of its own.
    private func handleReplay(_ message: JSONValue) {
        let uuid = message["uuid"]?.string
        if let uuid, sentMessageIds.remove(uuid) != nil { return }
        guard message["parent_tool_use_id"]?.string == nil,
              message["isSynthetic"]?.bool != true else { return }
        let content = message["message"]?["content"]
        let blocks = content?.array ?? []
        let text = content?.string ?? blocks
            .compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
            .joined(separator: "\n\n")
        let images = blocks.compactMap(Self.saveImageBlock)
        guard !text.isEmpty || !images.isEmpty else { return }
        openSyntheticTurnIfNeeded(for: message)
        guard let turnId = activeTurnId else { return }
        continuation.yield(.item(AgentItem(
            id: "user-\(uuid ?? UUID().uuidString.lowercased())",
            turnId: turnId,
            status: .completed,
            content: .userMessage(.init(text: text, images: images))
        )))
        recordAnchor(message, turnId: turnId)
    }

    /// Writes a base64 image block (a photo sent from the Claude app) to a
    /// file next to pasted images, for the chat to show.
    private static func saveImageBlock(_ block: JSONValue) -> String? {
        guard block["type"]?.string == "image",
              block["source"]?["type"]?.string == "base64",
              let base64 = block["source"]?["data"]?.string,
              let data = Data(base64Encoded: base64) else { return nil }
        let ext: String
        switch block["source"]?["media_type"]?.string {
        case "image/jpeg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        default: ext = "png"
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("remote-\(UUID().uuidString.prefix(8)).\(ext)")
        return (try? data.write(to: url)) != nil ? url.path : nil
    }

    private func handleBridgeState(_ message: JSONValue) {
        guard remoteControlName != nil, message["state"]?.string == "failed" else { return }
        remoteControlName = nil
        continuation.yield(.remoteControl(.failed(message["detail"]?.string ?? "Remote Control disconnected.")))
    }

    /// Top-level transcript messages carry a `uuid`; the last one of a turn
    /// is where a fork has to cut to drop everything after it.
    private func recordAnchor(_ message: JSONValue, turnId: String?) {
        guard let turnId,
              message["parent_tool_use_id"]?.string == nil,
              ["assistant", "user"].contains(message["type"]?.string ?? ""),
              let uuid = message["uuid"]?.string else { return }
        if let index = anchors.lastIndex(where: { $0.turnId == turnId }) {
            anchors[index].lastMessageId = uuid
        }
    }

    private var currentCursor: AgentResumeCursor {
        AgentResumeCursor(sessionId: sessionId ?? "", turns: anchors)
    }

    private func processEnded(_ ended: JSONLineProcess, status: Int32) {
        guard ended === process else { return }
        process = nil
        pendingControl.failAll(AgentError.notRunning)
        closeAllRequests()
        if needsRespawn {
            // Killed by a hard interrupt: report the turn as interrupted and
            // stay alive for the respawn on the next message.
            if let turn = activeTurnId {
                continuation.yield(.turnCompleted(id: turn, .interrupted))
                activeTurnId = nil
                mapper.turnId = nil
            }
            return
        }
        continuation.yield(.exited(AgentExit(status: status, stderr: ended.stderrTail, expected: stopping)))
        continuation.finish()
    }

    // MARK: - Control channel

    private func control(_ request: JSONValue, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard let process else { throw AgentError.notRunning }
        requestCounter += 1
        let id = "req_\(requestCounter)_\(UUID().uuidString.prefix(8))"
        let envelope: JSONValue = ["type": "control_request", "request_id": .string(id), "request": request]
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.failControl(id, AgentError.requestFailed("Claude didn't answer `\(request["subtype"]?.string ?? "request")`."))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            pendingControl.add(id, cont)
            Task {
                do {
                    try await process.send(envelope)
                } catch {
                    self.failControl(id, error)
                }
            }
        }
    }

    private func failControl(_ id: String, _ error: Error) {
        pendingControl.resolve(id, with: .failure(error))
    }

    private func handleControlResponse(_ response: JSONValue) {
        guard let id = response["request_id"]?.string else { return }
        if response["subtype"]?.string == "error" {
            pendingControl.resolve(id, with: .failure(AgentError.requestFailed(response["error"]?.string ?? "Request failed")))
        } else {
            pendingControl.resolve(id, with: .success(response["response"] ?? .object([:])))
        }
    }

    private func reply(to requestId: String, _ response: JSONValue) {
        guard let process else { return }
        let envelope: JSONValue = [
            "type": "control_response",
            "response": ["subtype": "success", "request_id": .string(requestId), "response": response]
        ]
        Task { try? await process.send(envelope) }
    }

    private func replyError(to requestId: String, _ message: String) {
        guard let process else { return }
        let envelope: JSONValue = [
            "type": "control_response",
            "response": ["subtype": "error", "request_id": .string(requestId), "error": .string(message)]
        ]
        Task { try? await process.send(envelope) }
    }

    private func handleControlRequest(_ message: JSONValue) {
        guard let requestId = message["request_id"]?.string,
              let request = message["request"] else { return }
        guard request["subtype"]?.string == "can_use_tool" else {
            // hook_callback / mcp_message: we register neither.
            replyError(to: requestId, "Unsupported request")
            return
        }
        let toolName = request["tool_name"]?.string ?? "tool"
        let input = request["input"] ?? .object([:])
        let toolUseId = request["tool_use_id"]?.string
        permissionRequests[requestId] = PermissionRequest(
            toolName: toolName,
            toolUseId: toolUseId,
            input: input,
            suggestions: request["permission_suggestions"]?.array ?? []
        )
        continuation.yield(.requestOpened(AgentRequest(
            id: requestId,
            turnId: activeTurnId,
            itemId: toolUseId,
            kind: Self.requestKind(toolName: toolName, input: input, request: request)
        )))
    }

    static func requestKind(toolName: String, input: JSONValue, request: JSONValue) -> AgentRequest.Kind {
        switch toolName {
        case "AskUserQuestion":
            let questions = (input["questions"]?.array ?? []).map { q in
                AgentQuestion(
                    // Answers are keyed by the question text, not an id.
                    id: q["question"]?.string ?? "",
                    header: q["header"]?.string,
                    prompt: q["question"]?.string ?? "",
                    options: (q["options"]?.array ?? []).map {
                        .init(label: $0["label"]?.string ?? "", description: $0["description"]?.string)
                    },
                    allowsMultiple: q["multiSelect"]?.bool ?? false,
                    allowsFreeform: true
                )
            }
            return .questions(questions)
        case "ExitPlanMode":
            return .plan(text: input["plan"]?.string ?? "")
        default:
            let category: AgentApproval.Category
            let title: String
            var detail: String?
            switch toolName {
            case "Bash":
                category = .command
                title = "Run this command?"
                detail = input["command"]?.string
            case "Edit", "MultiEdit", "Write", "NotebookEdit":
                category = .fileChange
                title = toolName == "Write" ? "Create or overwrite this file?" : "Edit this file?"
                detail = input["file_path"]?.string ?? input["notebook_path"]?.string
            case "Read", "Glob", "Grep", "LS":
                category = .fileRead
                title = "Read outside the workspace?"
                detail = request["blocked_path"]?.string ?? input["file_path"]?.string ?? input["path"]?.string
            case "WebFetch", "WebSearch":
                category = .network
                title = toolName == "WebFetch" ? "Fetch this URL?" : "Search the web?"
                detail = input["url"]?.string ?? input["query"]?.string
            default:
                category = .tool
                title = "Use \(request["display_name"]?.string ?? toolName)?"
                detail = input.object?.isEmpty == false ? input.prettyPrinted() : nil
            }
            // `description` is the agent's own label for the call: useful
            // for a command ("Run the test suite"), redundant for an edit
            // (it's the file name).
            let reason = request["decision_reason"]?.string
                ?? (category == .command ? request["description"]?.string : nil)
            return .approval(AgentApproval(
                category: category,
                title: title,
                detail: detail,
                reason: reason,
                allowsSessionScope: true
            ))
        }
    }

    private func closeAllRequests() {
        for id in permissionRequests.keys {
            continuation.yield(.requestClosed(id: id))
        }
        permissionRequests.removeAll()
    }

    // MARK: - Turns

    func send(_ input: AgentTurnInput) async throws {
        if needsRespawn || process == nil {
            guard config != nil, !stopping else { throw AgentError.notRunning }
            try await spawn(resume: true)
        }
        guard let process else { throw AgentError.notRunning }

        if let model = input.model, model != config?.model {
            try await setModel(model)
        }
        if input.interactionMode != interactionMode {
            interactionMode = input.interactionMode
            _ = try await control([
                "subtype": "set_permission_mode",
                "mode": .string(Self.claudeMode(for: runtimeMode, interaction: interactionMode))
            ])
            continuation.yield(.interactionModeChanged(interactionMode))
        }

        let turnId = UUID().uuidString.lowercased()
        activeTurnId = turnId
        mapper.turnId = turnId
        anchors.append(.init(turnId: turnId, lastMessageId: anchors.last?.lastMessageId))
        continuation.yield(.turnStarted(id: turnId))
        continuation.yield(.item(AgentItem(
            id: "user-\(turnId)",
            turnId: turnId,
            status: .completed,
            content: .userMessage(.init(text: input.text, images: input.images.map(\.path)))
        )))

        // Images first, text last: the CLI only recognises a slash command
        // when the final content block is text.
        var content: [JSONValue] = input.images.compactMap(Self.imageBlock)
        content.append(["type": "text", "text": .string(input.text)])
        let messageId = UUID().uuidString.lowercased()
        sentMessageIds.insert(messageId)
        let message: JSONValue = [
            "type": "user",
            "uuid": .string(messageId),
            "session_id": "",
            "message": ["role": "user", "content": .array(content)],
            "parent_tool_use_id": nil
        ]
        do {
            try await process.send(message)
        } catch {
            activeTurnId = nil
            mapper.turnId = nil
            continuation.yield(.turnCompleted(id: turnId, .failed(message: "Couldn't reach Claude.")))
            throw error
        }
    }

    func interrupt() async {
        guard let turnId = activeTurnId, let process else { return }
        closeAllRequests()
        do {
            _ = try await control(["subtype": "interrupt"], timeout: .seconds(5))
        } catch {
            // Fall through to the hard stop below.
        }
        // The CLI acknowledges interrupts even while resumed background
        // work keeps it busy (T3 Code hit this too). If the turn hasn't
        // wound down shortly after, kill the process; the next message
        // resumes the session.
        for _ in 0..<30 where activeTurnId == turnId {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard activeTurnId == turnId, process === self.process else { return }
        needsRespawn = true
        await process.terminate(grace: .seconds(1))
    }

    // MARK: - Requests

    func respond(to requestId: String, with decision: AgentApprovalDecision) async {
        guard let request = permissionRequests.removeValue(forKey: requestId) else { return }
        let response: JSONValue
        switch decision {
        case .allowOnce:
            response = ["behavior": "allow", "updatedInput": request.input]
        case .allowForSession:
            response = [
                "behavior": "allow",
                "updatedInput": request.input,
                "updatedPermissions": .array(Self.sessionPermissions(for: request))
            ]
        case let .deny(message):
            if let toolUseId = request.toolUseId { mapper.markDeclined(toolUseId) }
            response = ["behavior": "deny", "message": .string(message ?? "The user declined this action.")]
        case .cancel:
            if let toolUseId = request.toolUseId { mapper.markDeclined(toolUseId) }
            response = ["behavior": "deny", "message": "The user stopped this turn.", "interrupt": true]
        }
        reply(to: requestId, response)
        continuation.yield(.requestClosed(id: requestId))
    }

    /// "Allow for this session": the CLI's own suggestions, re-targeted at
    /// the session so nothing lands in the user's settings files. Falls
    /// back to a rule for the tool itself.
    private static func sessionPermissions(for request: PermissionRequest) -> [JSONValue] {
        let rewritten = request.suggestions.compactMap { suggestion -> JSONValue? in
            guard case var .object(dict) = suggestion else { return nil }
            dict["destination"] = "session"
            return .object(dict)
        }
        if !rewritten.isEmpty { return rewritten }
        return [[
            "type": "addRules",
            "rules": [["toolName": .string(request.toolName)]],
            "behavior": "allow",
            "destination": "session"
        ]]
    }

    func answer(_ requestId: String, answers: [String: [String]]) async {
        guard let request = permissionRequests.removeValue(forKey: requestId) else { return }
        guard case var .object(input) = request.input else { return }
        input["answers"] = .object(answers.mapValues { .string($0.joined(separator: ", ")) })
        reply(to: requestId, ["behavior": "allow", "updatedInput": .object(input)])
        continuation.yield(.requestClosed(id: requestId))
    }

    func resolvePlan(_ requestId: String, with decision: AgentPlanDecision) async -> AgentTurnInput? {
        guard let request = permissionRequests.removeValue(forKey: requestId) else { return nil }
        switch decision {
        case let .implement(mode):
            runtimeMode = mode
            interactionMode = .normal
            reply(to: requestId, [
                "behavior": "allow",
                "updatedInput": request.input,
                "updatedPermissions": [[
                    "type": "setMode",
                    "mode": .string(Self.claudeMode(for: mode, interaction: .normal)),
                    "destination": "session"
                ]]
            ])
            continuation.yield(.interactionModeChanged(.normal))
            continuation.yield(.runtimeModeChanged(mode))
        case let .keepPlanning(feedback):
            if let toolUseId = request.toolUseId { mapper.markDeclined(toolUseId) }
            let message = feedback?.nonBlank.map { "The user wants to keep planning. Their feedback: \($0)" }
                ?? "The user wants to keep planning before you implement anything."
            reply(to: requestId, ["behavior": "deny", "message": .string(message)])
        }
        continuation.yield(.requestClosed(id: requestId))
        return nil
    }

    // MARK: - Revert

    func revert(toBefore turnId: String) async throws {
        guard config != nil else { throw AgentError.notRunning }
        guard let index = anchors.firstIndex(where: { $0.turnId == turnId }) else {
            throw AgentError.unsupported("This turn can't be reverted in Claude's transcript.")
        }
        if let process {
            stopping = true
            self.process = nil
            await process.terminate(grace: .seconds(1))
        }
        stopping = false
        activeTurnId = nil
        mapper = ClaudeEventMapper()
        let newId = UUID().uuidString.lowercased()
        if index > 0, let cut = anchors[index - 1].lastMessageId {
            try await spawn(resume: true, fork: Fork(at: cut, forkAs: newId))
            anchors = Array(anchors.prefix(index))
        } else {
            // Nothing before this turn to keep: a fresh session.
            sessionId = newId
            anchors = []
            try await spawn(resume: false)
        }
        continuation.yield(.resumeUpdated(currentCursor))
    }

    // MARK: - Settings

    func setRuntimeMode(_ mode: AgentRuntimeMode) async throws {
        runtimeMode = mode
        guard process != nil, interactionMode == .normal else { return }
        _ = try await control([
            "subtype": "set_permission_mode",
            "mode": .string(Self.claudeMode(for: mode, interaction: .normal))
        ])
    }

    func setModel(_ model: String?) async throws {
        config?.model = model
        guard process != nil else { return }
        _ = try await control(["subtype": "set_model", "model": .optional(model)])
        if let model { continuation.yield(.modelChanged(model)) }
    }

    // MARK: - Remote Control

    func setRemoteControl(_ enabled: Bool, name: String?) async throws -> URL? {
        guard enabled else {
            remoteControlName = nil
            if process != nil { _ = try await control(["subtype": "remote_control", "enabled": false]) }
            return nil
        }
        if process == nil || needsRespawn {
            guard config != nil, !stopping else { throw AgentError.notRunning }
            try await spawn(resume: true)
        }
        let url = try await enableRemoteControl(name: name)
        remoteControlName = .some(name)
        return url
    }

    private func enableRemoteControl(name: String?) async throws -> URL? {
        var request: [String: JSONValue] = ["subtype": "remote_control", "enabled": true]
        if let name { request["name"] = .string(name) }
        let response = try await control(.object(request), timeout: .seconds(30))
        return response["session_url"]?.string.flatMap(URL.init(string:))
    }

    // MARK: - Mapping helpers

    static func claudeMode(for mode: AgentRuntimeMode, interaction: AgentInteractionMode) -> String {
        if interaction == .plan { return "plan" }
        switch mode {
        case .supervised: return "default"
        case .acceptEdits: return "acceptEdits"
        case .auto: return "auto"
        case .fullAccess: return "bypassPermissions"
        }
    }

    static func runtimeMode(fromClaude mode: String) -> AgentRuntimeMode? {
        switch mode {
        case "default", "manual": return .supervised
        case "acceptEdits": return .acceptEdits
        case "auto": return .auto
        case "bypassPermissions": return .fullAccess
        default: return nil
        }
    }

    /// The CLI's display names are family aliases ("Opus (1M context)"); the
    /// exact version is only in the description ("Opus 5.5 with 1M context
    /// · Best for…"). Lift it out: "Opus 5.5 1M", "Default (Opus 5.5 1M)".
    static func modelName(value: String, displayName: String?, description: String?) -> String {
        guard let head = description?.components(separatedBy: " · ").first?.nonBlank,
              head.first?.isLetter == true, head.contains(where: \.isNumber) else {
            return displayName ?? value
        }
        let name = head.replacingOccurrences(of: " with 1M context", with: " 1M")
        return value == "default" ? "Default (\(name))" : name
    }

    private func sessionInfo(from initialize: JSONValue) -> AgentSessionInfo {
        let models = (initialize["models"]?.array ?? []).compactMap { model -> AgentModelOption? in
            guard let value = model["value"]?.string else { return nil }
            return AgentModelOption(
                id: value,
                displayName: Self.modelName(
                    value: value,
                    displayName: model["displayName"]?.string,
                    description: model["description"]?.string
                ),
                description: model["description"]?.string,
                efforts: model["supportedEffortLevels"]?.array?.compactMap(\.string) ?? [],
                defaultEffort: nil,
                isDefault: value == "default"
            )
        }
        let commands = (initialize["commands"]?.array ?? []).compactMap { command -> AgentSlashCommand? in
            guard let name = command["name"]?.string else { return nil }
            return AgentSlashCommand(
                name: name,
                description: command["description"]?.string ?? "",
                argumentHint: command["argumentHint"]?.string?.nonBlank
            )
        }
        return AgentSessionInfo(
            resume: currentCursor,
            model: config?.model,
            models: models,
            commands: commands,
            cliVersion: nil
        )
    }

    private static func imageBlock(_ url: URL) -> JSONValue? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let mediaType: String
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": mediaType = "image/jpeg"
        case "gif": mediaType = "image/gif"
        case "webp": mediaType = "image/webp"
        default: mediaType = "image/png"
        }
        return [
            "type": "image",
            "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(data.base64EncodedString())]
        ]
    }

    private func emitNotice(_ level: AgentItem.Notice.Level, _ text: String) {
        continuation.yield(.item(.notice(level, text, turnId: activeTurnId)))
    }
}
