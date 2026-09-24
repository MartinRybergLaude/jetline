import XCTest
@testable import JetlineApp

/// End-to-end runs against the real CLIs. They cost tokens and need both
/// agents installed and logged in, so they only run when asked:
///
///     JETLINE_LIVE_AGENT_TESTS=1 swift test --filter LiveAgentTests
final class LiveAgentTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["JETLINE_LIVE_AGENT_TESTS"] == "1",
            "Set JETLINE_LIVE_AGENT_TESTS=1 to run against the real CLIs"
        )
    }

    func testClaudeApprovalInterruptAndResume() async throws {
        try await runScenario(kind: .claude, model: "haiku", effort: nil)
    }

    func testCodexApprovalInterruptAndResume() async throws {
        try await runScenario(kind: .codex, model: nil, effort: "low")
    }

    func testClaudeConversationRevert() async throws {
        try await runRevertScenario(kind: .claude, model: "haiku", effort: nil)
    }

    func testCodexConversationRevert() async throws {
        try await runRevertScenario(kind: .codex, model: nil, effort: "low")
    }

    /// Revert turns and check the agent forgot them. Arithmetic questions
    /// rather than "remember X": Claude's auto-memory can persist those to
    /// files outside the conversation, which no revert touches.
    private func runRevertScenario(kind: AgentProviderKind, model: String?, effort: String?) async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let config = AgentSessionConfig(
            cwd: repo.path, executable: try await resolve(kind), model: model, effort: effort,
            runtimeMode: .fullAccess, interactionMode: .normal, resume: nil
        )
        let recorder = try await Recorder.start(kind: kind, config: config)

        func ask(_ text: String) async throws -> String {
            let mark = recorder.mark
            try await recorder.provider.send(AgentTurnInput(text: text + " Do not use any tools."))
            let outcome = try await recorder.waitForTurn(since: mark, timeout: 120) { _ in .allowOnce }
            XCTAssertEqual(outcome, .completed)
            return recorder.turnIds(since: mark).first ?? ""
        }
        func history() async throws -> String {
            _ = try await ask("List, in order, the numbers from every arithmetic question I have asked you in this conversation, as `a+b` terms separated by commas. Nothing else.")
            return recorder.lastAssistantText.replacingOccurrences(of: " ", with: "")
        }

        _ = try await ask("What is 11+11? Reply with just the number.")
        let second = try await ask("What is 22+22? Reply with just the number.")
        try await recorder.provider.revert(toBefore: second)
        var answer = try await history()
        XCTAssertTrue(answer.contains("11+11"), "got: \(answer)")
        XCTAssertFalse(answer.contains("22+22"), "first revert; got: \(answer)")

        // Revert again inside the forked session.
        let third = try await ask("What is 33+33? Reply with just the number.")
        _ = try await ask("What is 44+44? Reply with just the number.")
        let fifth = try await ask("What is 55+55? Reply with just the number.")
        try await recorder.provider.revert(toBefore: fifth)
        answer = try await history()
        XCTAssertTrue(answer.contains("33+33") && answer.contains("44+44"), "second revert; got: \(answer)")
        XCTAssertFalse(answer.contains("55+55"), "second revert; got: \(answer)")

        // Cut at a point recorded before the latest fork.
        try await recorder.provider.revert(toBefore: third)
        answer = try await history()
        XCTAssertTrue(answer.contains("11+11"), "cross-fork revert; got: \(answer)")
        XCTAssertFalse(answer.contains("33+33") || answer.contains("44+44"), "cross-fork revert; got: \(answer)")
        await recorder.provider.stop()
    }

    /// 1. A turn that needs an approval (declined once, then allowed) and
    ///    writes a file.
    /// 2. A long turn, interrupted.
    /// 3. Stop, restart from the resume cursor, and check the agent still
    ///    remembers the first turn.
    private func runScenario(kind: AgentProviderKind, model: String?, effort: String?) async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let executable = try await resolve(kind)

        let config = AgentSessionConfig(
            cwd: repo.path, executable: executable, model: model, effort: effort,
            runtimeMode: .supervised, interactionMode: .normal, resume: nil
        )
        var recorder = try await Recorder.start(kind: kind, config: config)

        // Turn 1: approvals.
        var mark = recorder.mark
        try await recorder.provider.send(AgentTurnInput(
            text: "Use a shell command to create a file named note.txt containing exactly the word jetline. Do nothing else."
        ))
        let first = try await recorder.waitForTurn(since: mark, timeout: 180) { request in
            .allowOnce
        }
        XCTAssertEqual(first, .completed)
        let note = try String(contentsOf: repo.appendingPathComponent("note.txt"), encoding: .utf8)
        XCTAssertEqual(note.trimmingCharacters(in: .whitespacesAndNewlines), "jetline")
        XCTAssertGreaterThan(recorder.approvals, 0, "supervised mode should have asked")

        // Turn 1b: a declined command must not run.
        mark = recorder.mark
        try await recorder.provider.send(AgentTurnInput(
            text: "Use a shell command to create an empty file named declined.txt. If you are not allowed, stop and say so."
        ))
        let declinedTurn = try await recorder.waitForTurn(since: mark, timeout: 180) { _ in
            .deny(message: "The user declined.")
        }
        XCTAssertEqual(declinedTurn, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("declined.txt").path))
        XCTAssertTrue(recorder.items(since: mark).contains { $0.status == .declined }, "expected a declined item")

        // Turn 2: interrupt.
        mark = recorder.mark
        try await recorder.provider.send(AgentTurnInput(
            text: "Write a 3000 word essay about the history of the printing press. Do not use any tools."
        ))
        try await recorder.waitForText(since: mark, minimumCharacters: 200, timeout: 120)
        await recorder.provider.interrupt()
        let second = try await recorder.waitForTurn(since: mark, timeout: 60) { _ in .deny(message: nil) }
        XCTAssertEqual(second, .interrupted)

        // Resume in a fresh process.
        let cursor = try XCTUnwrap(recorder.info?.resume)
        await recorder.provider.stop()
        try await recorder.waitForExit(timeout: 15)

        var resumed = config
        resumed.resume = cursor
        recorder = try await Recorder.start(kind: kind, config: resumed)
        XCTAssertEqual(recorder.info?.resume, cursor)
        mark = recorder.mark
        try await recorder.provider.send(AgentTurnInput(
            text: "What was the name of the file you created earlier? Reply with just the file name."
        ))
        let third = try await recorder.waitForTurn(since: mark, timeout: 120) { _ in .deny(message: nil) }
        XCTAssertEqual(third, .completed)
        XCTAssertTrue(recorder.lastAssistantText.contains("note.txt"), "got: \(recorder.lastAssistantText)")
        await recorder.provider.stop()
    }

    // MARK: Helpers

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-live-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "hello\n".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-c", "user.email=t@t", "-c", "user.name=t", "init", "-q"]
        git.currentDirectoryURL = dir
        try git.run()
        git.waitUntilExit()
        return dir.resolvingSymlinksInPath()
    }

    private func resolve(_ kind: AgentProviderKind) async throws -> String {
        let name = kind.agentKind.executableName
        guard let path = await AgentLauncher.resolveOnPath(name) else {
            throw XCTSkip("\(name) not installed")
        }
        return path
    }
}

/// Consumes a provider's events and answers its requests.
private struct Recorder {
    let provider: any AgentProvider
    private let log: EventLog
    private(set) var info: AgentSessionInfo?

    static func start(kind: AgentProviderKind, config: AgentSessionConfig) async throws -> Recorder {
        let provider: any AgentProvider = kind == .claude ? ClaudeProvider() : CodexProvider()
        let log = EventLog()
        Task {
            for await event in provider.events { await log.append(event) }
        }
        try await provider.start(config)
        var recorder = Recorder(provider: provider, log: log)
        recorder.info = try await log.waitFor(timeout: 30) { events in
            events.lazy.compactMap { if case let .ready(info) = $0 { return info }; return nil }.first
        }
        return recorder
    }

    func turnIds(since start: Int) -> [String] {
        log.snapshot.dropFirst(start).compactMap { if case let .turnStarted(id) = $0 { return id }; return nil }
    }

    func items(since start: Int) -> [AgentItem] {
        finalItems(in: Array(log.snapshot.dropFirst(start)))
    }

    var approvals: Int { log.snapshot.filter { if case .requestOpened = $0 { return true }; return false }.count }

    var lastAssistantText: String {
        finalItems(in: log.snapshot).compactMap { item -> String? in
            if case let .assistantMessage(text) = item.content, !text.isEmpty { return text }
            return nil
        }.last ?? ""
    }

    /// Wait for the next turn to finish, answering approvals with `decide`.
    var mark: Int { log.count }

    func waitForTurn(
        since start: Int,
        timeout: TimeInterval,
        decide: @escaping @Sendable (AgentRequest) -> AgentApprovalDecision
    ) async throws -> AgentTurnOutcome {
        var handled: Set<String> = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let events = log.snapshot.dropFirst(start)
            if let outcome = events.lazy.compactMap({ event -> AgentTurnOutcome? in
                if case let .turnCompleted(_, outcome) = event { return outcome }
                return nil
            }).first {
                return outcome
            }
            for case let .requestOpened(request) in events where !handled.contains(request.id) {
                handled.insert(request.id)
                switch request.kind {
                case .approval:
                    await provider.respond(to: request.id, with: decide(request))
                case let .questions(questions):
                    await provider.answer(request.id, answers: Dictionary(uniqueKeysWithValues: questions.map { ($0.id, [$0.options.first?.label ?? "yes"]) }))
                case .plan:
                    await provider.resolvePlan(request.id, with: .implement(mode: .acceptEdits))
                }
            }
            if events.contains(where: { if case .exited = $0 { return true }; return false }) {
                throw AgentError.notRunning
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentError.requestFailed("Timed out waiting for the turn. Events:\n" + log.describe(from: start))
    }

    func waitForText(since start: Int, minimumCharacters: Int, timeout: TimeInterval) async throws {
        _ = try await log.waitFor(timeout: timeout) { events -> Bool? in
            let count = events.dropFirst(start).reduce(0) { total, event in
                if case let .delta(_, _, .assistantText, text) = event { return total + text.count }
                return total
            }
            return count >= minimumCharacters ? true : nil
        }
    }

    func waitForExit(timeout: TimeInterval) async throws {
        _ = try await log.waitFor(timeout: timeout) { events -> Bool? in
            events.contains { if case .exited = $0 { return true }; return false } ? true : nil
        }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AgentEvent] = []

    func append(_ event: AgentEvent) async {
        lock.withLock { events.append(event) }
    }

    var snapshot: [AgentEvent] { lock.withLock { events } }

    /// Compact dump for failure messages: deltas are summarised.
    func describe(from start: Int = 0) -> String {
        snapshot.dropFirst(start).compactMap { event -> String? in
            switch event {
            case .delta: return nil
            case let .item(item): return "item \(item.id) \(item.status) \(String(describing: item.content).prefix(160))"
            default: return String(describing: event).prefix(300).description
            }
        }.joined(separator: "\n")
    }
    var count: Int { lock.withLock { events.count } }

    func waitFor<T>(timeout: TimeInterval, _ match: ([AgentEvent]) -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = match(snapshot) { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AgentError.requestFailed("Timed out. Events:\n" + describe())
    }
}
