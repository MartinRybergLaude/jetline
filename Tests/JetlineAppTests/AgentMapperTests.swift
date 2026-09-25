import XCTest
@testable import JetlineApp

/// Replays transcripts recorded from real `claude` (2.1.281) and `codex
/// app-server` (0.156.1) sessions through the mappers. When a CLI update
/// changes its protocol, record a fresh transcript and add it here.
final class ClaudeEventMapperTests: XCTestCase {
    func testToolTurnProducesCommandFileChangeAndReply() throws {
        let events = try replayClaude("claude-tools")

        let command = try XCTUnwrap(lastItem(in: events) { if case .command = $0 { return true }; return false })
        guard case let .command(cmd) = command.content else { return XCTFail() }
        XCTAssertEqual(cmd.command, "cat a.txt")
        XCTAssertEqual(cmd.output, "hello")
        XCTAssertEqual(cmd.exitCode, 0)
        XCTAssertEqual(command.status, .completed)

        let write = try XCTUnwrap(lastItem(in: events) { if case .fileChange = $0 { return true }; return false })
        guard case let .fileChange(change) = write.content else { return XCTFail() }
        XCTAssertEqual(change.edits.first?.kind, .add)
        XCTAssertEqual(change.edits.first?.path, "/tmp/repo/b.txt")
        XCTAssertEqual(change.edits.first?.diff, "@@ -1,0 +1,1 @@\n+world")

        XCTAssertTrue(events.contains(.turnCompleted(id: "turn-1", .completed)))
        let replies = finalItems(in: events).compactMap { item -> String? in
            if case let .assistantMessage(text) = item.content { return text }
            return nil
        }
        XCTAssertEqual(replies.first, "done")
        XCTAssertTrue(events.contains { if case .usage = $0 { return true }; return false })
    }

    func testStreamedTextMatchesFinalMessage() throws {
        let events = try replayClaude("claude-interrupt")
        // Deltas for the essay item, folded, must equal the finalized text.
        var streamed: [String: String] = [:]
        for case let .delta(itemId, _, .assistantText, text) in events {
            streamed[itemId, default: ""] += text
        }
        let finals = finalItems(in: events)
        for (id, text) in streamed {
            guard let item = finals.first(where: { $0.id == id }),
                  case let .assistantMessage(final) = item.content else { continue }
            XCTAssertTrue(final.hasPrefix(text) || text.hasPrefix(final), "Deltas diverged for \(id)")
        }
        XCTAssertFalse(streamed.isEmpty)
    }

    func testInterruptedTurnIsReportedAsInterrupted() throws {
        let events = try replayClaude("claude-interrupt")
        XCTAssertTrue(events.contains(.turnCompleted(id: "turn-1", .interrupted)))
        XCTAssertTrue(events.contains(.turnCompleted(id: "turn-2", .completed)))
    }

    func testThinkingIsStreamedAsReasoning() throws {
        let events = try replayClaude("claude-interrupt")
        let reasoning = finalItems(in: events).first { if case .reasoning = $0.content { return true }; return false }
        guard case let .reasoning(text)? = reasoning?.content else { return XCTFail("no reasoning item") }
        XCTAssertTrue(text.contains("tension"))
    }

    func testDeclinedToolAndQuestions() throws {
        var requests: [AgentRequest.Kind] = []
        let events = try replayClaude("claude-approvals") { message, mapper in
            guard message["type"]?.string == "control_request",
                  let request = message["request"],
                  request["subtype"]?.string == "can_use_tool" else { return }
            let tool = request["tool_name"]?.string ?? ""
            requests.append(ClaudeProvider.requestKind(toolName: tool, input: request["input"] ?? .null, request: request))
            // The recorded session declined the first Bash call.
            if tool == "Bash", requests.count == 1, let id = request["tool_use_id"]?.string {
                mapper.markDeclined(id)
            }
        }

        guard case let .approval(bash) = requests[0] else { return XCTFail() }
        XCTAssertEqual(bash.category, .command)
        XCTAssertEqual(bash.detail, "touch z.txt")
        guard case let .approval(write) = requests[1] else { return XCTFail() }
        XCTAssertEqual(write.category, .fileChange)
        guard case let .questions(questions) = requests[2] else { return XCTFail() }
        XCTAssertEqual(questions.first?.id, "Which color do you prefer?")
        XCTAssertEqual(questions.first?.options.map(\.label), ["Red", "Blue"])

        let bashItem = finalItems(in: events).first { if case .command = $0.content { return true }; return false }
        XCTAssertEqual(bashItem?.status, .declined)
    }

    func testAPIErrorReportedAsSuccessIsAFailure() {
        let result: JSONValue = [
            "type": "result", "subtype": "success", "is_error": false,
            "api_error_status": 529, "result": "Overloaded"
        ]
        XCTAssertEqual(ClaudeEventMapper.outcome(of: result), .failed(message: "Claude's API is overloaded (529). Try again shortly."))
    }

    func testRateLimitEventReportsEachWindow() {
        let info: JSONValue = [
            "status": "allowed", "rateLimitType": "five_hour",
            "unifiedWindows": [
                "seven_day": ["utilization": .double(0.35), "resetsAt": 1790640000],
                "five_hour": ["utilization": .double(0.14), "resetsAt": 1790331000],
            ],
        ]
        XCTAssertEqual(ClaudeEventMapper.rateLimits(info), [
            AgentRateLimit(id: "five_hour", name: "5-hour limit", used: 0.14, resetsAt: Date(timeIntervalSince1970: 1790331000)),
            AgentRateLimit(id: "seven_day", name: "Weekly limit", used: 0.35, resetsAt: Date(timeIntervalSince1970: 1790640000)),
        ])
    }

    func testDiagnosticErrorsStayHiddenAndAbortsAreInterrupts() {
        let aborted: JSONValue = [
            "type": "result", "subtype": "error_during_execution", "is_error": true,
            "terminal_reason": "aborted_tools", "errors": ["[ede_diagnostic] tool aborted"]
        ]
        XCTAssertEqual(ClaudeEventMapper.outcome(of: aborted), .interrupted)
        let quietSuccess: JSONValue = ["type": "result", "subtype": "success", "is_error": true]
        XCTAssertEqual(ClaudeEventMapper.outcome(of: quietSuccess), .completed)
        XCTAssertEqual(
            ClaudeEventMapper.outcome(of: quietSuccess, failureHint: "Not logged in"),
            .failed(message: "Not logged in")
        )
    }

    func testTaskToolsDriveTodos() {
        var mapper = ClaudeEventMapper()
        mapper.turnId = "t"
        func toolUse(_ id: String, _ name: String, _ input: JSONValue) -> JSONValue {
            ["type": "assistant", "message": ["id": .string("m-\(id)"), "content": [["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]]]]
        }
        func result(_ id: String, _ structured: JSONValue) -> JSONValue {
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": .string(id), "content": "ok"]]], "tool_use_result": structured]
        }
        _ = mapper.map(toolUse("a", "TaskCreate", ["subject": "Write tests"]))
        var events = mapper.map(result("a", ["task": ["id": "1", "subject": "Write tests"]]))
        XCTAssertTrue(events.contains(.todos([AgentTodo(text: "Write tests", status: .pending)])))
        _ = mapper.map(toolUse("b", "TaskUpdate", ["taskId": "1", "status": "in_progress"]))
        events = mapper.map(result("b", ["success": true]))
        XCTAssertTrue(events.contains(.todos([AgentTodo(text: "Write tests", status: .inProgress)])))
    }

    func testRuntimeModeRoundTrip() {
        for mode in AgentRuntimeMode.allCases {
            let claude = ClaudeProvider.claudeMode(for: mode, interaction: .normal)
            XCTAssertEqual(ClaudeProvider.runtimeMode(fromClaude: claude), mode)
        }
        XCTAssertEqual(ClaudeProvider.claudeMode(for: .fullAccess, interaction: .plan), "plan")
    }

    func testModelNamesCarryTheExactVersion() {
        func name(_ value: String, _ display: String?, _ description: String?) -> String {
            ClaudeProvider.modelName(value: value, displayName: display, description: description)
        }
        XCTAssertEqual(name("default", "Default (recommended)", "Opus 5.5 with 1M context · Best for everyday, complex tasks"), "Default (Opus 5.5 1M)")
        XCTAssertEqual(name("opus[1m]", "Opus (1M context)", "Opus 5.5 with 1M context · Best for everyday, complex tasks"), "Opus 5.5 1M")
        XCTAssertEqual(name("claude-fable-5-1[1m]", "Fable", "Fable 5.1 · Most capable for your hardest and longest-running tasks"), "Fable 5.1")
        XCTAssertEqual(name("haiku", "Haiku", "Haiku 4.5 · Fastest for quick answers"), "Haiku 4.5")
        XCTAssertEqual(name("custom", "Custom", "Uses your configured model"), "Custom")
        XCTAssertEqual(name("custom", nil, nil), "custom")
    }

    // MARK: Helpers

    /// Replay a transcript, starting a new turn (`turn-N`) before the first
    /// message after each result — the provider does this when it sends a
    /// user message.
    private func replayClaude(
        _ name: String,
        onMessage: (JSONValue, inout ClaudeEventMapper) -> Void = { _, _ in }
    ) throws -> [AgentEvent] {
        var mapper = ClaudeEventMapper()
        var events: [AgentEvent] = []
        var turn = 0
        for message in try loadFixture(name) {
            onMessage(message, &mapper)
            let type = message["type"]?.string
            if type == "control_request" || type == "control_response" { continue }
            if mapper.turnId == nil, type == "system", message["subtype"]?.string == "init" {
                turn += 1
                mapper.turnId = "turn-\(turn)"
            }
            events += mapper.map(message)
        }
        return events
    }
}

final class CodexEventMapperTests: XCTestCase {
    func testRateLimitSnapshotReportsPrimaryAndSecondary() {
        let snapshot: JSONValue = [
            "primary": ["usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1790331000],
            "secondary": ["usedPercent": 40, "windowDurationMins": 10080],
        ]
        XCTAssertEqual(CodexEventMapper.rateLimits(snapshot), [
            AgentRateLimit(id: "primary", name: "5-hour limit", used: 0.12, resetsAt: Date(timeIntervalSince1970: 1790331000)),
            AgentRateLimit(id: "secondary", name: "Weekly limit", used: 0.4, resetsAt: nil),
        ])
    }

    func testApprovalsInterruptAndResumeTranscript() throws {
        var mapper = CodexEventMapper()
        var events: [AgentEvent] = []
        for message in try loadFixture("codex-approvals-interrupt-resume") {
            guard let method = message["method"]?.string, message["id"] == nil else { continue }
            events += mapper.map(method: method, params: message["params"] ?? .null)
        }

        let turnStarts = events.compactMap { if case let .turnStarted(id) = $0 { return id }; return nil }
        XCTAssertEqual(turnStarts.count, 3)

        let outcomes = events.compactMap { if case let .turnCompleted(_, outcome) = $0 { return outcome }; return nil }
        XCTAssertEqual(outcomes, [.completed, .interrupted, .completed])

        let finals = finalItems(in: events)
        let command = finals.first { if case .command = $0.content { return true }; return false }
        guard case let .command(cmd)? = command?.content else { return XCTFail() }
        XCTAssertEqual(cmd.command, "touch z.txt", "shell wrapper should be stripped")
        XCTAssertEqual(command?.status, .declined)

        let change = finals.first { if case .fileChange = $0.content { return true }; return false }
        guard case let .fileChange(fc)? = change?.content else { return XCTFail() }
        XCTAssertEqual(fc.edits.first?.kind, .add)
        XCTAssertEqual(fc.edits.first?.diff, "@@ -0,0 +1,1 @@\n+world")
        XCTAssertEqual(change?.status, .completed)

        let replies = finals.compactMap { item -> String? in
            if case let .assistantMessage(text) = item.content { return text }
            return nil
        }
        XCTAssertTrue(replies.contains("Done. `b.txt` contains `world`; `touch z.txt` was rejected."))
        XCTAssertTrue(events.contains { if case .usage = $0 { return true }; return false })
        XCTAssertTrue(events.contains(.requestClosed(id: "codex-0")))
    }

    func testUnwrapShell() {
        XCTAssertEqual(CodexEventMapper.unwrapShell("/bin/zsh -lc 'touch z.txt'"), "touch z.txt")
        XCTAssertEqual(CodexEventMapper.unwrapShell("/bin/bash -lc 'echo '\\''hi'\\'''"), "echo 'hi'")
        XCTAssertEqual(CodexEventMapper.unwrapShell("git status"), "git status")
    }

    func testUserMessageEchoAdoptsClientId() {
        let raw: JSONValue = [
            "type": "userMessage", "id": "server-id", "clientId": "user-abc",
            "content": [["type": "text", "text": "hi", "text_elements": []]]
        ]
        let item = CodexEventMapper.item(from: raw, turnId: "t")
        XCTAssertEqual(item?.id, "user-abc")
    }

    func testVersionParsing() {
        XCTAssertEqual(CodexProvider.cliVersion(fromUserAgent: "jetline/0.156.1 (Mac OS 27.0.0; arm64)"), "0.156.1")
        XCTAssertEqual(CodexProvider.compare("0.156.1", "0.150.0"), .orderedDescending)
        XCTAssertEqual(CodexProvider.compare("0.99", "0.150.0"), .orderedAscending)
    }
}

// MARK: - Shared helpers

func loadFixture(_ name: String) throws -> [JSONValue] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/Agents"))
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { try JSONValue.parse(Data($0.utf8)) }
}

/// The last snapshot of every item, in first-seen order.
func finalItems(in events: [AgentEvent]) -> [AgentItem] {
    var order: [String] = []
    var latest: [String: AgentItem] = [:]
    for case let .item(item) in events {
        if latest[item.id] == nil { order.append(item.id) }
        latest[item.id] = item
    }
    return order.compactMap { latest[$0] }
}

func lastItem(in events: [AgentEvent], where match: (AgentItem.Content) -> Bool) -> AgentItem? {
    finalItems(in: events).last { match($0.content) }
}
