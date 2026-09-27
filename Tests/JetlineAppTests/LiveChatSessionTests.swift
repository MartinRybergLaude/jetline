import XCTest
@testable import JetlineApp

/// Drives `ChatEngine` — reducer, checkpoints, persistence, revert — on
/// top of the real CLIs. Opt-in like `LiveAgentTests`.
@MainActor
final class LiveChatSessionTests: XCTestCase {
    private var repo: URL!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JETLINE_LIVE_AGENT_TESTS"] == "1")
        // Keep the test's chats out of the real database. Must run before
        // anything touches `Database.shared`.
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-live-db-\(UUID().uuidString.prefix(8))")
        setenv("JETLINE_DATA_DIR", data.path, 1)
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetline-chat-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "print('hi')\n".write(to: repo.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        _ = try await GitRunner.runChecked(["init", "-q"], cwd: repo.path)
        _ = try await GitRunner.runChecked(["add", "."], cwd: repo.path)
        _ = try await GitRunner.runChecked(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], cwd: repo.path)
    }

    override func tearDown() async throws {
        if let repo { try? FileManager.default.removeItem(at: repo) }
    }

    func testClaudeChatSession() async throws {
        try await runChat(provider: .claude, model: "haiku", effort: nil)
    }

    func testCodexChatSession() async throws {
        try await runChat(provider: .codex, model: nil, effort: "low")
    }

    private func runChat(provider: AgentProviderKind, model: String?, effort: String?) async throws {
        let session = ChatEngine(
            workspaceId: "test-workspace",
            cwd: repo.path,
            provider: provider,
            model: model,
            effort: effort,
            runtimeMode: .supervised,
            rateLimits: AgentRateLimits(),
            executableResolver: { await AgentLauncher.resolveOnPath($0.agentKind.executableName) }
        )

        // Turn 1: an edit that needs approval.
        session.send(text: "Create a file named hello.txt containing exactly the word jetline, using a shell command. Do nothing else.")
        XCTAssertEqual(session.turns.count, 1, "the user message shows immediately")
        XCTAssertTrue(session.title.hasPrefix("Create a file named hello.txt") && session.title.hasSuffix("…"))
        try await runTurn(session, timeout: 180)

        let turn = try XCTUnwrap(session.turns.last)
        XCTAssertEqual(turn.status, .completed, turn.errorMessage ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent("hello.txt").path))
        XCTAssertTrue(turn.items.contains { if case .command = $0.item.content { return true }; return false })
        XCTAssertEqual(turn.items.filter { $0.kind == .user }.count, 1, "optimistic message and echo must merge")
        try await waitUntil(timeout: 20) { turn.stat != nil }
        XCTAssertEqual(turn.stat?.files, 1)

        // Turn 2, then reload the chat from the database.
        session.send(text: "Reply with just the word OK. Do not use any tools.")
        try await runTurn(session, timeout: 120)
        XCTAssertEqual(session.turns.count, 2)
        try await Task.sleep(for: .milliseconds(500))
        let record = try XCTUnwrap(ChatStore.thread(id: session.id))
        let restored = ChatEngine(record: record, cwd: repo.path, rateLimits: AgentRateLimits(), executableResolver: { _ in nil })
        XCTAssertEqual(restored.turns.count, 2)
        XCTAssertEqual(restored.turns.map { $0.items.count }, session.turns.map { $0.items.count })
        XCTAssertEqual(restored.title, session.title)
        XCTAssertNotNil(record.resumeCursor)

        // Revert turn 1: file gone, both turns gone, message back in draft.
        let draft = await session.revert(to: session.turns[0])
        XCTAssertTrue(session.turns.isEmpty)
        XCTAssertNil(session.banner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("hello.txt").path))
        XCTAssertTrue(draft?.text.hasPrefix("Create a file named hello.txt") == true)
        XCTAssertTrue(ChatStore.transcript(threadId: session.id).turns.isEmpty)

        // The chat still works after reverting.
        session.send(text: "Reply with just the word AGAIN. Do not use any tools.")
        try await runTurn(session, timeout: 120)
        XCTAssertEqual(session.turns.last?.status, .completed)
        await session.shutdown()
    }

    /// Wait for the running turn to end, approving whatever it asks.
    private func runTurn(_ session: ChatEngine, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await waitUntil(timeout: 30) { session.isWorking }
        while Date() < deadline {
            if let request = session.requests.first {
                switch request.kind {
                case .approval: session.respond(to: request, with: .allowOnce)
                case let .questions(questions):
                    session.answer(request, answers: Dictionary(uniqueKeysWithValues: questions.map { ($0.id, [$0.options.first?.label ?? "yes"]) }))
                case .plan: session.resolvePlan(request, with: .implement(mode: .acceptEdits))
                }
            }
            if !session.isWorking { return }
            if case let .failed(message) = session.connection { XCTFail(message); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("turn didn't finish in \(timeout)s")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw AgentError.requestFailed("condition not met in \(timeout)s") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
