import Foundation

/// Translates Claude Code's stream-json output into `AgentEvent`s.
///
/// Pure and synchronous so it can be driven from recorded transcripts in
/// tests. The provider feeds it every stdout message except the control
/// channel (`control_request` / `control_response`), which it handles
/// itself.
///
/// Claude streams one message at a time: `stream_event`s carry the partial
/// content blocks (`content_block_start` → deltas → `content_block_stop`),
/// and a complete `assistant` message follows for each finished block.
/// Text and thinking blocks become items keyed `<message id>#<block index>`;
/// tool calls are keyed by their `tool_use` id, which the matching
/// `tool_result` later refers back to.
struct ClaudeEventMapper {
    /// Turn that new items belong to. Set by the provider when it sends a
    /// user message.
    var turnId: String?

    private var messageId: String?
    /// Content blocks of the message currently streaming, by index.
    private var blocks: [Int: Block] = [:]
    /// Item ids already finalized from `assistant` messages, so a block's
    /// complete message isn't matched twice.
    private var finalizedBlocks: Set<String> = []
    /// Tool calls seen so far, by tool_use id. Tool results arrive as
    /// separate `user` messages and need the call's name and input.
    private var tools: [String: ToolState] = [:]
    /// Tool uses the user declined. Their results come back as errors and
    /// should read as "declined", not "failed".
    private var declinedToolUseIds: Set<String> = []
    private var lastUsage: AgentTokenUsage?
    private var contextWindow: Int?
    /// Claude's task list (`TaskCreate` / `TaskUpdate` / `TaskList`), by
    /// id in creation order, mirrored into `.todos`.
    private var tasks: [(id: String, subject: String, status: AgentTodo.Status, blockedBy: [String])] = []
    /// Why the current turn is likely to fail, from an assistant message's
    /// `error` field. A result can report failure without saying why.
    private var failureHint: String?
    /// Usage-limit windows already announced this turn.
    private var announcedLimits: Set<String> = []

    private struct Block {
        var itemId: String
        var type: String
        var parentId: String?
    }

    private struct ToolState {
        var item: AgentItem
        var name: String
        var input: JSONValue
    }

    /// Record that the user declined `toolUseId`, before its result lands.
    mutating func markDeclined(_ toolUseId: String) {
        declinedToolUseIds.insert(toolUseId)
    }

    /// The tool item for a tool_use id, for approval prompts.
    func toolItem(_ toolUseId: String) -> AgentItem? {
        tools[toolUseId]?.item
    }

    mutating func map(_ message: JSONValue) -> [AgentEvent] {
        switch message["type"]?.string {
        case "stream_event":
            return mapStreamEvent(message)
        case "assistant":
            return mapAssistant(message)
        case "user":
            return mapUser(message)
        case "system":
            return mapSystem(message)
        case "result":
            return mapResult(message)
        case "rate_limit_event":
            return mapRateLimit(message)
        default:
            return []
        }
    }

    // MARK: - Streaming

    private mutating func mapStreamEvent(_ message: JSONValue) -> [AgentEvent] {
        guard let event = message["event"] else { return [] }
        let parentId = message["parent_tool_use_id"]?.string
        // Subagents stream interleaved with the parent. Their partial
        // messages would reset the parent's block state (and their usage
        // isn't the parent's context), so only the parent streams; a
        // subagent's tool calls still arrive in its complete `assistant`
        // messages. T3 Code drops these the same way.
        guard parentId == nil else { return [] }
        switch event["type"]?.string {
        case "message_start":
            messageId = event["message"]?["id"]?.string
            blocks.removeAll()
            if let usage = event["message"]?["usage"] {
                recordUsage(usage)
            }
            return []

        case "content_block_start":
            guard let index = event["index"]?.int,
                  let block = event["content_block"],
                  let type = block["type"]?.string else { return [] }
            switch type {
            case "text", "thinking":
                let itemId = "\(messageId ?? "message")#\(index)"
                blocks[index] = Block(itemId: itemId, type: type, parentId: parentId)
                let content: AgentItem.Content = type == "text"
                    ? .assistantMessage(text: block["text"]?.string ?? "")
                    : .reasoning(text: block["thinking"]?.string ?? "")
                return [.item(AgentItem(
                    id: itemId, turnId: turnId, parentId: parentId,
                    status: .inProgress, content: content
                ))]
            case "tool_use", "server_tool_use":
                guard let toolUseId = block["id"]?.string else { return [] }
                blocks[index] = Block(itemId: toolUseId, type: "tool_use", parentId: parentId)
                let name = block["name"]?.string ?? "tool"
                return upsertTool(id: toolUseId, name: name, input: .object([:]), parentId: parentId)
            default:
                return []
            }

        case "content_block_delta":
            guard let index = event["index"]?.int,
                  let block = blocks[index],
                  let delta = event["delta"] else { return [] }
            switch delta["type"]?.string {
            case "text_delta":
                guard let text = delta["text"]?.string, !text.isEmpty else { return [] }
                return [.delta(itemId: block.itemId, turnId: turnId, kind: .assistantText, text: text)]
            case "thinking_delta":
                guard let text = delta["thinking"]?.string, !text.isEmpty else { return [] }
                return [.delta(itemId: block.itemId, turnId: turnId, kind: .reasoningText, text: text)]
            default:
                // input_json_delta: the complete input arrives with the
                // `assistant` message a moment later; partial JSON isn't
                // worth rendering.
                return []
            }

        case "message_delta":
            if let usage = event["usage"] { recordUsage(usage) }
            return []

        default:
            return []
        }
    }

    // MARK: - Complete messages

    private mutating func mapAssistant(_ message: JSONValue) -> [AgentEvent] {
        guard let body = message["message"],
              let content = body["content"]?.array else { return [] }
        let parentId = message["parent_tool_use_id"]?.string
        let msgId = body["id"]?.string ?? messageId ?? UUID().uuidString
        if parentId == nil, let usage = body["usage"] { recordUsage(usage) }
        if parentId == nil {
            switch message["error"]?.string {
            case "authentication_failed":
                failureHint = "Claude isn't logged in. Run `claude` in a terminal and log in, then retry."
            case "rate_limit":
                failureHint = "Claude's usage limit was reached."
            case nil:
                break
            case let other?:
                failureHint = "Claude reported an error: \(other.replacingOccurrences(of: "_", with: " "))."
            }
        }
        if let model = body["model"]?.string, contextWindow == nil {
            contextWindow = Self.defaultContextWindow(for: model)
        }

        var events: [AgentEvent] = []
        for (offset, block) in content.enumerated() {
            guard let type = block["type"]?.string else { continue }
            switch type {
            case "text", "thinking":
                // Subagent narration belongs to the subagent's own result,
                // which arrives as the Task tool's output.
                if parentId != nil { continue }
                let itemId = matchStreamedBlock(type: type, messageId: msgId)
                    ?? "\(msgId)#\(type)-\(offset)"
                finalizedBlocks.insert(itemId)
                let text = (type == "text" ? block["text"] : block["thinking"])?.string ?? ""
                events.append(.item(AgentItem(
                    id: itemId, turnId: turnId, parentId: parentId, status: .completed,
                    content: type == "text" ? .assistantMessage(text: text) : .reasoning(text: text)
                )))
            case "tool_use", "server_tool_use":
                guard let toolUseId = block["id"]?.string else { continue }
                events += upsertTool(
                    id: toolUseId,
                    name: block["name"]?.string ?? "tool",
                    input: block["input"] ?? .object([:]),
                    parentId: parentId
                )
            default:
                continue
            }
        }
        return events
    }

    /// The streamed block this complete message corresponds to: the
    /// earliest not-yet-finalized block of the same type in the current
    /// message. `assistant` messages arrive in block order, one block each.
    private func matchStreamedBlock(type: String, messageId: String) -> String? {
        guard messageId == self.messageId else { return nil }
        return blocks
            .filter { $0.value.type == type && !finalizedBlocks.contains($0.value.itemId) }
            .min { $0.key < $1.key }?
            .value.itemId
    }

    private mutating func mapUser(_ message: JSONValue) -> [AgentEvent] {
        guard let content = message["message"]?["content"]?.array else { return [] }
        let toolUseResult = message["tool_use_result"]
        var events: [AgentEvent] = []
        for block in content where block["type"]?.string == "tool_result" {
            guard let toolUseId = block["tool_use_id"]?.string,
                  var state = tools[toolUseId] else { continue }
            let isError = block["is_error"]?.bool ?? false
            let output = Self.resultText(block["content"])
            let status: AgentItem.Status
            if declinedToolUseIds.contains(toolUseId) {
                status = .declined
            } else if isError {
                status = .failed
            } else {
                status = .completed
            }
            if !isError, let todos = applyTaskTool(name: state.name, input: state.input, result: toolUseResult) {
                events.append(.todos(todos))
            }
            state.item.status = status
            state.item.content = ClaudeTools.completed(
                state.item.content,
                name: state.name,
                input: state.input,
                output: output,
                isError: isError,
                structured: toolUseResult
            )
            tools[toolUseId] = state
            events.append(.item(state.item))
        }
        return events
    }

    private mutating func mapSystem(_ message: JSONValue) -> [AgentEvent] {
        switch message["subtype"]?.string {
        case "init":
            var events: [AgentEvent] = []
            if let model = message["model"]?.string {
                events.append(.modelChanged(model))
                contextWindow = contextWindow ?? Self.defaultContextWindow(for: model)
            }
            if let mode = message["permissionMode"]?.string {
                events += Self.modeEvents(for: mode)
            }
            return events
        case "status":
            guard let mode = message["permissionMode"]?.string else { return [] }
            return Self.modeEvents(for: mode)
        case "compact_boundary":
            let id = message["uuid"]?.string ?? UUID().uuidString
            return [.item(AgentItem(id: id, turnId: turnId, status: .completed, content: .compaction))]
        case "api_retry":
            let attempt = message["attempt"]?.int.map { " (attempt \($0))" } ?? ""
            let id = message["uuid"]?.string ?? UUID().uuidString
            return [.item(AgentItem(
                id: id, turnId: turnId, status: .completed,
                content: .notice(.init(level: .warning, text: "API error, retrying\(attempt)…"))
            ))]
        default:
            return []
        }
    }

    private mutating func mapResult(_ message: JSONValue) -> [AgentEvent] {
        guard let turnId else { return [] }
        var events: [AgentEvent] = []
        if let window = message["modelUsage"]?.object?.values.compactMap({ $0["contextWindow"]?.int }).max() {
            contextWindow = window
        }
        if var usage = lastUsage {
            usage.contextWindow = contextWindow
            events.append(.usage(usage))
        }
        events.append(.turnCompleted(id: turnId, Self.outcome(of: message, failureHint: failureHint)))
        self.turnId = nil
        declinedToolUseIds.removeAll()
        failureHint = nil
        announcedLimits.removeAll()
        return events
    }

    /// A rejected usage window parks the turn: no more messages and no
    /// result arrive, so without a notice the chat just spins. Accounts
    /// with overage keep running through a rejection.
    private mutating func mapRateLimit(_ message: JSONValue) -> [AgentEvent] {
        guard let info = message["rate_limit_info"] else { return [] }
        var events: [AgentEvent] = []
        let windows = Self.rateLimits(info)
        if !windows.isEmpty { events.append(.rateLimits(windows)) }
        return events + rejection(info)
    }

    /// `unifiedWindows`' per-window utilization, keyed by window type.
    static func rateLimits(_ info: JSONValue) -> [AgentRateLimit] {
        guard let windows = info["unifiedWindows"]?.object else { return [] }
        return windows.compactMap { key, window in
            guard let used = window["utilization"]?.double else { return nil }
            return AgentRateLimit(
                id: key,
                name: limitName(key),
                used: min(1, max(0, used)),
                resetsAt: window["resetsAt"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
        .sorted { $0.id < $1.id }
    }

    private static func limitName(_ type: String) -> String {
        switch type {
        case "five_hour": return "5-hour limit"
        case "seven_day": return "Weekly limit"
        case "seven_day_opus": return "Weekly Opus limit"
        case "seven_day_sonnet": return "Weekly Sonnet limit"
        default: return windowName(type).prefix(1).uppercased() + windowName(type).dropFirst() + " limit"
        }
    }

    private mutating func rejection(_ info: JSONValue) -> [AgentEvent] {
        guard let turnId, info["status"]?.string == "rejected" else { return [] }
        let overage = ["allowed", "allowed_warning"].contains(info["overageStatus"]?.string ?? "")
            || info["isUsingOverage"]?.bool == true
        guard !overage else { return [] }
        let window = info["rateLimitType"]?.string ?? "usage"
        let key = "\(window):\(info["resetsAt"]?.int ?? 0)"
        guard !announcedLimits.contains(key) else { return [] }
        announcedLimits.insert(key)
        failureHint = "Claude's usage limit was reached."
        var text = "Claude's \(Self.windowName(window)) usage limit is reached; the turn is paused."
        if let resets = info["resetsAt"]?.int {
            let date = Date(timeIntervalSince1970: TimeInterval(resets))
            text += " It resets \(date.formatted(date: .omitted, time: .shortened))."
        }
        return [.item(AgentItem(
            id: "limit-\(key)", turnId: turnId, status: .completed,
            content: .notice(.init(level: .warning, text: text))
        ))]
    }

    private static func windowName(_ type: String) -> String {
        switch type {
        case "five_hour": return "5-hour"
        case "seven_day": return "7-day"
        case "seven_day_opus": return "7-day Opus"
        case "seven_day_sonnet": return "7-day Sonnet"
        default: return type.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Fold a task tool's result into the task list. Returns the new todos
    /// when it changed. Mirrors T3 Code's `applyClaudeTaskToolResult`.
    private mutating func applyTaskTool(name: String, input: JSONValue, result: JSONValue?) -> [AgentTodo]? {
        func status(_ value: JSONValue?) -> AgentTodo.Status {
            switch value?.string {
            case "completed": return .completed
            case "in_progress": return .inProgress
            default: return .pending
            }
        }
        func strings(_ value: JSONValue?) -> [String] {
            value?.array?.compactMap { $0.string?.nonBlank } ?? []
        }
        switch name {
        case "TaskList":
            guard let list = result?["tasks"]?.array else { return nil }
            tasks = list.compactMap { task in
                guard let id = task["id"]?.string?.nonBlank, let subject = task["subject"]?.string?.nonBlank else { return nil }
                return (id, subject, status(task["status"]), strings(task["blockedBy"]))
            }
        case "TaskCreate":
            guard let id = result?["task"]?["id"]?.string?.nonBlank,
                  let subject = result?["task"]?["subject"]?.string?.nonBlank ?? input["subject"]?.string?.nonBlank else { return nil }
            tasks.removeAll { $0.id == id }
            tasks.append((id, subject, status(input["status"]), strings(input["blockedBy"])))
        case "TaskUpdate":
            guard let id = input["taskId"]?.string?.nonBlank ?? result?["taskId"]?.string?.nonBlank,
                  let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
            if let subject = input["subject"]?.string?.nonBlank { tasks[index].subject = subject }
            if input["status"]?.string != nil { tasks[index].status = status(input["status"]) }
            tasks[index].blockedBy += strings(input["addBlockedBy"]).filter { !tasks[index].blockedBy.contains($0) }
            let removed = Set(strings(input["removeBlockedBy"]))
            tasks[index].blockedBy.removeAll { removed.contains($0) }
        default:
            return nil
        }
        return tasks.map { task in
            let blocked = task.blockedBy.isEmpty ? "" : " (blocked by #\(task.blockedBy.joined(separator: ", #")))"
            return AgentTodo(text: task.subject + blocked, status: task.status)
        }
    }

    /// Turn outcome from a `result` message, ported from T3 Code's
    /// `resultOutcome`. The CLI's signals are subtle:
    /// - repeated 529s arrive as `subtype: "success"` with
    ///   `api_error_status: 529`;
    /// - `is_error` on a success result only means failure when the turn
    ///   already said why (`failureHint`, from an assistant `error`);
    /// - `terminal_reason` names structured failures and user aborts;
    /// - `errors` can hold internal `[ede_diagnostic]` entries that must
    ///   not reach the user.
    static func outcome(of result: JSONValue, failureHint: String? = nil) -> AgentTurnOutcome {
        let subtype = result["subtype"]?.string ?? "success"
        let isError = result["is_error"]?.bool ?? false
        let terminal = result["terminal_reason"]?.string
        let errors = result["errors"]?.array?.compactMap(\.string) ?? []
        let errorsText = errors.joined(separator: " ").lowercased()
        let successTaggedFailure = subtype == "success" && isError

        let structured: String?
        if subtype == "success", result["api_error_status"]?.int == 529 {
            structured = "Claude's API is overloaded (529). Try again shortly."
        } else if let message = terminalError(terminal, failureHint: failureHint) {
            structured = message
        } else {
            structured = successTaggedFailure ? failureHint : nil
        }
        let listed = subtype == "success" && !successTaggedFailure
            ? nil
            : errors.first { !$0.hasPrefix("[ede_diagnostic]") }?.nonBlank
        if let structured { return .failed(message: listed ?? structured) }
        if subtype == "success" { return .completed }

        let interrupted = terminal == "aborted_tools" || terminal == "aborted_streaming"
            || errorsText.contains("interrupt")
            || (subtype == "error_during_execution" && !isError
                && (errorsText.contains("request was aborted") || errorsText.contains("interrupted by user") || errorsText.contains("aborted")))
        if interrupted { return .interrupted }
        return .failed(message: listed ?? result["result"]?.string?.nonBlank ?? subtype.replacingOccurrences(of: "_", with: " "))
    }

    private static func terminalError(_ reason: String?, failureHint: String?) -> String? {
        switch reason {
        case "api_error": return failureHint ?? "Claude gave up after repeated API errors."
        case "malformed_tool_use_exhausted": return "Claude gave up after repeated malformed tool calls."
        case "budget_exhausted": return "Claude stopped: the turn's token budget was exhausted."
        case "structured_output_retry_exhausted": return "Claude couldn't produce the requested structured output."
        case "tool_deferred_unavailable": return "Claude couldn't resume a deferred tool call: the tool is no longer available."
        case "turn_setup_failed": return "Claude couldn't start the turn."
        case "blocking_limit": return "Claude stopped: a usage limit blocked the request."
        case "rapid_refill_breaker": return "Claude stopped: the context refilled too quickly after compaction."
        case "prompt_too_long": return "Claude stopped: the conversation exceeds the model's context window. Try /compact."
        case "image_error": return "Claude stopped: an image in the conversation couldn't be processed."
        case "model_error": return "Claude stopped: the model returned an error."
        default: return nil
        }
    }

    // MARK: - Tools

    private mutating func upsertTool(id: String, name: String, input: JSONValue, parentId: String?) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if name == "TodoWrite", let todos = ClaudeTools.todos(from: input) {
            events.append(.todos(todos))
        }
        let content = ClaudeTools.content(name: name, input: input)
        var item = tools[id]?.item ?? AgentItem(
            id: id, turnId: turnId, parentId: parentId, status: .inProgress, content: content
        )
        item.content = content
        tools[id] = ToolState(item: item, name: name, input: input)
        events.append(.item(item))
        return events
    }

    // MARK: - Helpers

    private mutating func recordUsage(_ usage: JSONValue) {
        let input = (usage["input_tokens"]?.int ?? 0)
            + (usage["cache_creation_input_tokens"]?.int ?? 0)
            + (usage["cache_read_input_tokens"]?.int ?? 0)
        let output = usage["output_tokens"]?.int ?? 0
        guard input + output > 0 else { return }
        lastUsage = AgentTokenUsage(contextTokens: input + output, contextWindow: contextWindow)
    }

    private static func defaultContextWindow(for model: String) -> Int {
        model.contains("[1m]") ? 1_000_000 : 200_000
    }

    private static func modeEvents(for claudeMode: String) -> [AgentEvent] {
        if claudeMode == "plan" { return [.interactionModeChanged(.plan)] }
        guard let mode = ClaudeProvider.runtimeMode(fromClaude: claudeMode) else { return [] }
        return [.interactionModeChanged(.normal), .runtimeModeChanged(mode)]
    }

    /// Flatten a tool_result's `content`, which is a string or an array of
    /// text/image blocks.
    static func resultText(_ content: JSONValue?) -> String {
        switch content {
        case let .string(s)?:
            return s
        case let .array(blocks)?:
            return blocks.compactMap { block -> String? in
                if block["type"]?.string == "text" { return block["text"]?.string }
                if block["type"]?.string == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        default:
            return ""
        }
    }
}

/// Maps Claude's built-in tools onto the neutral item kinds.
enum ClaudeTools {
    static func content(name: String, input: JSONValue) -> AgentItem.Content {
        switch name {
        case "Bash":
            return .command(.init(
                command: input["command"]?.string ?? "",
                summary: input["description"]?.string
            ))
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return .fileChange(.init(edits: proposedEdits(name: name, input: input)))
        case "WebSearch":
            return .webSearch(query: input["query"]?.string ?? "")
        case "Task", "Agent":
            return .subagent(.init(
                description: input["description"]?.string ?? "Subagent",
                prompt: input["prompt"]?.string,
                agentType: input["subagent_type"]?.string
            ))
        case "ExitPlanMode":
            return .plan(text: input["plan"]?.string ?? "")
        default:
            let (server, tool) = splitMCPName(name)
            return .tool(.init(name: tool, server: server, input: input, summary: summary(name: name, input: input)))
        }
    }

    /// Fold a tool result into the item's content.
    static func completed(
        _ content: AgentItem.Content,
        name: String,
        input: JSONValue,
        output: String,
        isError: Bool,
        structured: JSONValue?
    ) -> AgentItem.Content {
        switch content {
        case var .command(command):
            if let stdout = structured?["stdout"]?.string {
                let stderr = structured?["stderr"]?.string ?? ""
                command.output = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            } else {
                command.output = output
            }
            if isError, command.output.isEmpty { command.output = output }
            command.exitCode = isError ? (command.exitCode ?? 1) : 0
            return .command(command)
        case var .fileChange(change):
            if !isError, let edit = appliedEdit(name: name, input: input, structured: structured) {
                change.edits = [edit]
            }
            return .fileChange(change)
        case var .subagent(agent):
            agent.result = output
            return .subagent(agent)
        case var .tool(tool):
            tool.output = output
            return .tool(tool)
        default:
            return content
        }
    }

    static func todos(from input: JSONValue) -> [AgentTodo]? {
        guard let list = input["todos"]?.array else { return nil }
        return list.compactMap { entry in
            guard let text = entry["content"]?.string else { return nil }
            let status: AgentTodo.Status
            switch entry["status"]?.string {
            case "completed": status = .completed
            case "in_progress": status = .inProgress
            default: status = .pending
            }
            return AgentTodo(text: text, status: status)
        }
    }

    // MARK: File edits

    /// What the edit will do, from its input alone — shown while the call
    /// waits for approval, before any result exists.
    private static func proposedEdits(name: String, input: JSONValue) -> [AgentItem.FileEdit] {
        let path = input["file_path"]?.string ?? input["notebook_path"]?.string ?? ""
        switch name {
        case "Write":
            let lines = (input["content"]?.string ?? "").splitLines()
            return [.init(path: path, kind: .update, diff: hunk(old: [], new: lines))]
        case "Edit":
            let old = (input["old_string"]?.string ?? "").splitLines()
            let new = (input["new_string"]?.string ?? "").splitLines()
            return [.init(path: path, kind: .update, diff: hunk(old: old, new: new))]
        case "MultiEdit":
            let hunks = (input["edits"]?.array ?? []).map { edit in
                hunk(
                    old: (edit["old_string"]?.string ?? "").splitLines(),
                    new: (edit["new_string"]?.string ?? "").splitLines()
                )
            }
            return [.init(path: path, kind: .update, diff: hunks.joined(separator: "\n"))]
        default:
            return [.init(path: path, kind: .update, diff: nil)]
        }
    }

    /// The edit as applied, from the result's `structuredPatch`, which has
    /// real line numbers.
    private static func appliedEdit(name: String, input: JSONValue, structured: JSONValue?) -> AgentItem.FileEdit? {
        guard let structured, structured.object != nil else { return nil }
        let path = structured["filePath"]?.string ?? input["file_path"]?.string ?? ""
        if structured["type"]?.string == "create" {
            let lines = (structured["content"]?.string ?? "").splitLines()
            return .init(path: path, kind: .add, diff: hunk(old: [], new: lines))
        }
        guard let patches = structured["structuredPatch"]?.array, !patches.isEmpty else { return nil }
        let diff = patches.map { patch -> String in
            let header = "@@ -\(patch["oldStart"]?.int ?? 0),\(patch["oldLines"]?.int ?? 0) "
                + "+\(patch["newStart"]?.int ?? 0),\(patch["newLines"]?.int ?? 0) @@"
            let lines = patch["lines"]?.array?.compactMap(\.string) ?? []
            return ([header] + lines).joined(separator: "\n")
        }.joined(separator: "\n")
        return .init(path: path, kind: .update, diff: diff)
    }

    private static func hunk(old: [String], new: [String]) -> String {
        let header = "@@ -1,\(old.count) +1,\(new.count) @@"
        return ([header] + old.map { "-" + $0 } + new.map { "+" + $0 }).joined(separator: "\n")
    }

    // MARK: Summaries

    private static func splitMCPName(_ name: String) -> (server: String?, tool: String) {
        guard name.hasPrefix("mcp__") else { return (nil, name) }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2 else { return (nil, name) }
        return (parts[0], parts.dropFirst().joined(separator: "__"))
    }

    private static func summary(name: String, input: JSONValue) -> String? {
        func file(_ key: String) -> String? {
            input[key]?.string.map { ($0 as NSString).lastPathComponent }
        }
        switch name {
        case "Read": return file("file_path").map { "Read \($0)" }
        case "Glob": return input["pattern"]?.string.map { "Found \($0)" }
        case "Grep": return input["pattern"]?.string.map { "Searched for “\($0)”" }
        case "LS": return file("path").map { "Listed \($0)" }
        case "WebFetch": return input["url"]?.string.map { "Fetched \($0)" }
        case "Skill": return input["skill"]?.string.map { "Used skill \($0)" }
        case "AskUserQuestion": return "Asked a question"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList": return "Updated the plan"
        case "EnterPlanMode": return "Entered plan mode"
        default: return nil
        }
    }
}

extension String {
    /// Lines without their terminators; a trailing newline doesn't produce
    /// an empty last line.
    func splitLines() -> [String] {
        guard !isEmpty else { return [] }
        var lines = components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
