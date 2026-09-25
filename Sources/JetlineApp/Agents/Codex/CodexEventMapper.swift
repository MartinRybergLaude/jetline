import Foundation

/// Translates `codex app-server` notifications into `AgentEvent`s.
///
/// Pure, like `ClaudeEventMapper`, so recorded transcripts can drive it in
/// tests. Codex already speaks in turns and items, so most of this is a
/// field-by-field rename; the work is in normalising `ThreadItem` variants
/// onto the shared item kinds.
struct CodexEventMapper {
    /// Items by id, kept so approval requests (which only carry an item id)
    /// can describe what they're approving.
    private(set) var items: [String: AgentItem] = [:]
    /// Reasoning items that have streamed summary text. Codex can stream
    /// both a summary and the raw reasoning for one item; showing both
    /// would duplicate it, and the summary is the readable one.
    private var summarizedReasoning: Set<String> = []
    /// Plan items completed during the current turn. A plan-mode turn that
    /// ends with one becomes a plan approval request.
    private(set) var completedPlans: [String: String] = [:]

    mutating func map(method: String, params: JSONValue) -> [AgentEvent] {
        switch method {
        case "turn/started":
            guard let id = params["turn"]?["id"]?.string else { return [] }
            completedPlans.removeAll()
            return [.turnStarted(id: id)]

        case "turn/completed":
            guard let turn = params["turn"], let id = turn["id"]?.string else { return [] }
            return [.turnCompleted(id: id, Self.outcome(of: turn))]

        case "item/started", "item/completed":
            guard let raw = params["item"],
                  var item = Self.item(from: raw, turnId: params["turnId"]?.string) else { return [] }
            if method == "item/completed", item.status == .inProgress {
                item.status = .completed
            }
            // A completed snapshot carries the full text; keep what the
            // deltas accumulated if the snapshot's text is empty (Codex
            // doesn't always repeat it).
            if let previous = items[item.id] {
                item = Self.merge(previous: previous, snapshot: item)
            }
            items[item.id] = item
            if method == "item/completed", case let .plan(text) = item.content {
                completedPlans[item.id] = text
            }
            return [.item(item)]

        case "item/agentMessage/delta":
            return delta(params, kind: .assistantText)

        case "item/reasoning/summaryTextDelta":
            if let id = params["itemId"]?.string { summarizedReasoning.insert(id) }
            return delta(params, kind: .reasoningText)

        case "item/reasoning/summaryPartAdded":
            guard let id = params["itemId"]?.string, summarizedReasoning.contains(id) else { return [] }
            return appendText("\n\n", itemId: id, turnId: params["turnId"]?.string, kind: .reasoningText)

        case "item/reasoning/textDelta":
            guard let id = params["itemId"]?.string, !summarizedReasoning.contains(id) else { return [] }
            return delta(params, kind: .reasoningText)

        case "item/plan/delta":
            return delta(params, kind: .planText)

        case "item/commandExecution/outputDelta":
            return delta(params, kind: .commandOutput)

        case "turn/plan/updated":
            let steps = (params["plan"]?.array ?? []).compactMap { step -> AgentTodo? in
                guard let text = step["step"]?.string else { return nil }
                let status: AgentTodo.Status
                switch step["status"]?.string {
                case "completed": status = .completed
                case "inProgress", "in_progress": status = .inProgress
                default: status = .pending
                }
                return AgentTodo(text: text, status: status)
            }
            return [.todos(steps)]

        case "thread/tokenUsage/updated":
            guard let usage = params["tokenUsage"],
                  let last = usage["last"]?["totalTokens"]?.int else { return [] }
            return [.usage(AgentTokenUsage(contextTokens: last, contextWindow: usage["modelContextWindow"]?.int))]

        case "account/rateLimits/updated":
            let windows = Self.rateLimits(params["rateLimits"])
            return windows.isEmpty ? [] : [.rateLimits(windows)]

        case "serverRequest/resolved":
            guard let id = params["requestId"] else { return [] }
            return [.requestClosed(id: CodexProvider.requestKey(id))]

        case "thread/compacted":
            return [.item(AgentItem(
                id: "compaction-\(UUID().uuidString)", turnId: params["turnId"]?.string,
                status: .completed, content: .compaction
            ))]

        case "model/rerouted":
            guard let model = params["toModel"]?.string ?? params["model"]?.string else { return [] }
            return [.modelChanged(model)]

        case "error":
            guard let message = params["error"]?["message"]?.string else { return [] }
            let willRetry = params["willRetry"]?.bool ?? false
            return [notice(
                willRetry ? .warning : .error,
                willRetry ? "\(message) Retrying…" : message,
                turnId: params["turnId"]?.string
            )]

        case "warning", "configWarning", "deprecationNotice":
            guard let text = params["message"]?.string ?? params["summary"]?.string else { return [] }
            return [notice(.warning, text, turnId: params["turnId"]?.string)]

        default:
            return []
        }
    }

    // MARK: - Items

    static func item(from raw: JSONValue, turnId: String?) -> AgentItem? {
        guard let type = raw["type"]?.string, let id = raw["id"]?.string else { return nil }
        let status = Self.status(raw["status"]?.string)
        let content: AgentItem.Content
        var itemId = id
        switch type {
        case "userMessage":
            // Our own optimistic item used `clientUserMessageId` as its id;
            // adopt it so the echo replaces rather than duplicates it.
            if let clientId = raw["clientId"]?.string { itemId = clientId }
            let parts = raw["content"]?.array ?? []
            let text = parts.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }
                .joined(separator: "\n")
            let images = parts.compactMap { $0["type"]?.string == "localImage" ? $0["path"]?.string : nil }
            content = .userMessage(.init(text: text, images: images))
        case "agentMessage":
            content = .assistantMessage(text: raw["text"]?.string ?? "")
        case "reasoning":
            let summary = raw["summary"]?.array?.compactMap(\.string) ?? []
            let full = raw["content"]?.array?.compactMap(\.string) ?? []
            content = .reasoning(text: (summary.isEmpty ? full : summary).joined(separator: "\n\n"))
        case "commandExecution":
            content = .command(.init(
                command: displayCommand(raw),
                cwd: raw["cwd"]?.string,
                output: raw["aggregatedOutput"]?.string ?? "",
                exitCode: raw["exitCode"]?.int,
                durationMs: raw["durationMs"]?.int
            ))
        case "fileChange":
            let edits = (raw["changes"]?.array ?? []).map(fileEdit)
            content = .fileChange(.init(edits: edits))
        case "mcpToolCall":
            let output: String?
            if let error = raw["error"]?["message"]?.string {
                output = error
            } else {
                output = raw["result"]?["content"]?.array.map(contentText)
            }
            content = .tool(.init(
                name: raw["tool"]?.string ?? "tool",
                server: raw["server"]?.string,
                input: raw["arguments"],
                output: output
            ))
        case "dynamicToolCall":
            content = .tool(.init(
                name: raw["tool"]?.string ?? "tool",
                server: raw["namespace"]?.string,
                input: raw["arguments"],
                output: raw["contentItems"]?.array.map(contentText)
            ))
        case "collabAgentToolCall":
            let tool = raw["tool"]?.string ?? "agent"
            content = .subagent(.init(
                description: collabDescription(tool),
                prompt: raw["prompt"]?.string,
                agentType: raw["model"]?.string
            ))
        case "webSearch":
            content = .webSearch(query: raw["query"]?.string ?? "")
        case "imageView":
            let path = raw["path"]?.string ?? ""
            content = .tool(.init(name: "view_image", summary: "Viewed \((path as NSString).lastPathComponent)"))
        case "plan":
            content = .plan(text: raw["text"]?.string ?? "")
        case "contextCompaction":
            content = .compaction
        case "enteredReviewMode":
            content = .notice(.init(level: .info, text: "Started review"))
        case "exitedReviewMode":
            content = .notice(.init(level: .info, text: "Finished review"))
        default:
            return nil
        }
        return AgentItem(id: itemId, turnId: turnId, status: status ?? .inProgress, content: content)
    }

    private static func merge(previous: AgentItem, snapshot: AgentItem) -> AgentItem {
        var merged = snapshot
        switch (previous.content, snapshot.content) {
        case let (.assistantMessage(old), .assistantMessage(new)) where new.isEmpty:
            merged.content = .assistantMessage(text: old)
        case let (.reasoning(old), .reasoning(new)) where new.isEmpty:
            merged.content = .reasoning(text: old)
        case let (.plan(old), .plan(new)) where new.isEmpty:
            merged.content = .plan(text: old)
        case let (.command(old), .command(new)) where new.output.isEmpty && !old.output.isEmpty:
            var command = new
            command.output = old.output
            merged.content = .command(command)
        default:
            break
        }
        return merged
    }

    private static func status(_ raw: String?) -> AgentItem.Status? {
        switch raw {
        case "inProgress": return .inProgress
        case "completed": return .completed
        case "failed": return .failed
        case "declined": return .declined
        case "interrupted": return .interrupted
        default: return nil
        }
    }

    static func outcome(of turn: JSONValue) -> AgentTurnOutcome {
        switch turn["status"]?.string {
        case "interrupted":
            return .interrupted
        case "failed":
            return .failed(message: turn["error"]?["message"]?.string ?? "The turn failed.")
        default:
            return .completed
        }
    }

    /// Codex wraps every command in the user's shell (`/bin/zsh -lc '…'`).
    /// Show what the model actually asked for.
    static func displayCommand(_ raw: JSONValue) -> String {
        let command = raw["command"]?.string ?? ""
        return unwrapShell(command)
    }

    static func unwrapShell(_ command: String) -> String {
        let prefixes = ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -lc ", "zsh -lc ", "bash -lc ", "sh -c ", "/bin/sh -c "]
        guard let prefix = prefixes.first(where: command.hasPrefix) else { return command }
        var rest = String(command.dropFirst(prefix.count))
        if rest.hasPrefix("'"), rest.hasSuffix("'"), rest.count >= 2 {
            rest = String(rest.dropFirst().dropLast())
            return rest.replacingOccurrences(of: "'\\''", with: "'")
        }
        if rest.hasPrefix("\""), rest.hasSuffix("\""), rest.count >= 2 {
            return String(rest.dropFirst().dropLast())
        }
        return rest
    }

    private static func fileEdit(_ change: JSONValue) -> AgentItem.FileEdit {
        let path = change["path"]?.string ?? ""
        let rawDiff = change["diff"]?.string
        switch change["kind"]?["type"]?.string {
        case "add":
            // New files carry their contents, not a diff.
            let lines = (rawDiff ?? "").splitLines()
            let diff = (["@@ -0,0 +1,\(lines.count) @@"] + lines.map { "+" + $0 }).joined(separator: "\n")
            return .init(path: path, kind: .add, diff: diff)
        case "delete":
            let lines = (rawDiff ?? "").splitLines()
            let diff = (["@@ -1,\(lines.count) +0,0 @@"] + lines.map { "-" + $0 }).joined(separator: "\n")
            return .init(path: path, kind: .delete, diff: diff)
        default:
            let moved = change["kind"]?["move_path"]?.string
            return .init(path: path, kind: moved == nil ? .update : .move, diff: rawDiff, movedTo: moved)
        }
    }

    private static func contentText(_ blocks: [JSONValue]) -> String {
        blocks.compactMap { block in
            block["text"]?.string ?? (block["type"]?.string?.contains("image") == true ? "[image]" : nil)
        }.joined(separator: "\n")
    }

    private static func collabDescription(_ tool: String) -> String {
        switch tool {
        case "spawnAgent": return "Spawned a subagent"
        case "sendInput", "sendMessage", "followupTask": return "Messaged a subagent"
        case "wait": return "Waited for subagents"
        case "closeAgent": return "Closed a subagent"
        case "resumeAgent": return "Resumed a subagent"
        case "interruptAgent": return "Interrupted a subagent"
        default: return "Subagent"
        }
    }

    // MARK: - Helpers

    private mutating func delta(_ params: JSONValue, kind: AgentStreamKind) -> [AgentEvent] {
        guard let id = params["itemId"]?.string, let text = params["delta"]?.string, !text.isEmpty else { return [] }
        return appendText(text, itemId: id, turnId: params["turnId"]?.string, kind: kind)
    }

    private mutating func appendText(_ text: String, itemId: String, turnId: String?, kind: AgentStreamKind) -> [AgentEvent] {
        if var item = items[itemId] {
            item.append(text, kind: kind)
            items[itemId] = item
        }
        return [.delta(itemId: itemId, turnId: turnId, kind: kind, text: text)]
    }

    private func notice(_ level: AgentItem.Notice.Level, _ text: String, turnId: String?) -> AgentEvent {
        .item(AgentItem(
            id: "notice-\(UUID().uuidString)", turnId: turnId,
            status: .completed, content: .notice(.init(level: level, text: text))
        ))
    }

    /// A `RateLimitSnapshot`'s primary and secondary windows. A sparse
    /// update can leave either out; the session keeps the last one seen.
    static func rateLimits(_ snapshot: JSONValue?) -> [AgentRateLimit] {
        guard let snapshot else { return [] }
        return ["primary", "secondary"].compactMap { key in
            guard let window = snapshot[key], let used = window["usedPercent"]?.double else { return nil }
            return AgentRateLimit(
                id: key,
                name: window["windowDurationMins"]?.int.map(AgentRateLimit.name(minutes:)) ?? (key == "primary" ? "Usage limit" : "Secondary limit"),
                used: min(1, max(0, used / 100)),
                resetsAt: window["resetsAt"]?.int.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }
}
