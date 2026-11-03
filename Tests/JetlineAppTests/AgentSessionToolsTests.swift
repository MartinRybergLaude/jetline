import XCTest
@testable import JetlineApp

/// The session tools, run the way `jetlined mcp` runs them: through
/// `Engine.runAgentTool`. No agent CLI runs: chats are attached with an
/// executable resolver that finds nothing, so a sent message fails its turn
/// instead of reaching a real agent.
@MainActor
final class AgentSessionToolsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = TestSupport.dataDir
    }

    private var engine: Engine!
    private var chats: [ChatEngine] = []

    override func setUp() async throws {
        engine = Engine()
    }

    override func tearDown() async throws {
        for chat in chats { chat.close() }
        chats = []
        engine = nil
    }

    // MARK: Helpers

    /// A repository and its checkout's workspace id, the caller a user's
    /// chat on the default branch would have.
    private func makeRepository() async throws -> (Repository, callerId: String) {
        let repo = try await engine.addRepository(path: try await TestSupport.makeRepo())
        return (repo, engine.repositoryBaseWorkspaceId(for: repo))
    }

    private func call(_ tool: String, _ arguments: JSONValue = [:], as callerId: String) async throws -> (JSONValue, isError: Bool) {
        let result = await engine.runAgentTool(tool, arguments: arguments, callerId: callerId)
        if result.isError { return (.string(result.text), true) }
        return (try JSONValue.parse(Data(result.text.utf8)), false)
    }

    private func createWorkspace(_ name: String, as callerId: String) async throws -> String {
        let (created, isError) = try await call("create_workspace", ["name": .string(name)], as: callerId)
        XCTAssertFalse(isError, "\(created)")
        return try XCTUnwrap(created["id"]?.string)
    }

    private func attachChat(to workspaceId: String) throws -> ChatEngine {
        let ws = try XCTUnwrap(engine.workspaceById(workspaceId))
        let chat = ChatEngine(
            workspaceId: ws.id,
            cwd: ws.worktreePath,
            provider: .claude,
            model: nil,
            effort: nil,
            runtimeMode: .supervised,
            rateLimits: AgentRateLimits(),
            executableResolver: { _ in nil }
        )
        engine.workspaceState(for: ws.id).chats.append(chat)
        chats.append(chat)
        return chat
    }

    // MARK: Dispatching

    func testListSendReadAndWaitOnADispatchedChat() async throws {
        let (_, callerId) = try await makeRepository()
        let childId = try await createWorkspace("child", as: callerId)
        let chat = try attachChat(to: childId)

        let (listed, _) = try await call("list_sessions", as: callerId)
        let entry = try XCTUnwrap(listed["sessions"]?.array?.first { $0["session_id"]?.string == chat.id })
        XCTAssertEqual(entry["workspace_id"]?.string, childId)
        XCTAssertEqual(entry["kind"]?.string, "chat")
        XCTAssertEqual(entry["you_created_workspace"]?.bool, true)

        let (sent, sendFailed) = try await call("send_message", [
            "session_ids": [.string(chat.id)],
            "text": "Run the tests and fix what fails."
        ], as: callerId)
        XCTAssertFalse(sendFailed, "\(sent)")
        XCTAssertEqual(sent["sent"]?.array?.first?["session_id"]?.string, chat.id)
        XCTAssertEqual(chat.turns.first?.userMessage?.text, "Run the tests and fix what fails.")

        // With no CLI to start, the turn fails and the chat stops working.
        let (waited, _) = try await call("wait_for_sessions", ["session_ids": [.string(chat.id)], "timeout_seconds": 10], as: callerId)
        XCTAssertEqual(waited["ready"]?.array?.first?["session_id"]?.string, chat.id)
        XCTAssertEqual(waited["timed_out"]?.bool, false)

        let (read, _) = try await call("read_session", ["session_id": .string(chat.id)], as: callerId)
        XCTAssertEqual(read["kind"]?.string, "chat")
        let turn = try XCTUnwrap(read["turns"]?.array?.last)
        XCTAssertEqual(turn["prompt"]?.string, "Run the tests and fix what fails.")
        XCTAssertEqual(turn["status"]?.string, "failed")
        XCTAssertNotNil(turn["error"]?.string)
    }

    func testOneMessageReachesSeveralChats() async throws {
        let (_, callerId) = try await makeRepository()
        let first = try attachChat(to: try await createWorkspace("first", as: callerId))
        let second = try attachChat(to: try await createWorkspace("second", as: callerId))

        let (sent, isError) = try await call("send_message", [
            "session_ids": [.string(first.id), .string(second.id)],
            "text": "Rebase on main before you push."
        ], as: callerId)
        XCTAssertFalse(isError, "\(sent)")
        XCTAssertEqual(sent["sent"]?.array?.count, 2)
        XCTAssertEqual(first.turns.last?.userMessage?.text, "Rebase on main before you push.")
        XCTAssertEqual(second.turns.last?.userMessage?.text, "Rebase on main before you push.")
    }

    func testABadIdSendsToNoChat() async throws {
        let (_, callerId) = try await makeRepository()
        let chat = try attachChat(to: try await createWorkspace("child", as: callerId))

        let (reply, isError) = try await call("send_message", [
            "session_ids": [.string(chat.id), "no-such-session"],
            "text": "Hello"
        ], as: callerId)
        XCTAssertTrue(isError)
        XCTAssertTrue(reply.string?.contains("No open session no-such-session") == true, "\(reply)")
        XCTAssertTrue(chat.turns.isEmpty, "nothing is sent when one id is wrong")
    }

    // MARK: Limits

    func testAChatInTheCallersOwnWorkspaceCantBeMessaged() async throws {
        let (_, callerId) = try await makeRepository()
        let own = try attachChat(to: callerId)

        let (reply, isError) = try await call("send_message", ["session_ids": [.string(own.id)], "text": "Hi"], as: callerId)
        XCTAssertTrue(isError)
        XCTAssertTrue(reply.string?.contains("your own workspace") == true, "\(reply)")
        XCTAssertTrue(own.turns.isEmpty)
    }

    func testSessionsGoOnlyInWorkspacesTheCallerCreated() async throws {
        let (_, callerId) = try await makeRepository()

        let (reply, isError) = try await call("start_session", ["workspace_id": .string(callerId), "prompt": "Go"], as: callerId)
        XCTAssertTrue(isError)
        XCTAssertTrue(reply.string?.contains("workspaces you created") == true, "\(reply)")
        XCTAssertTrue(engine.workspaceState(for: callerId).chats.isEmpty)
    }

    func testAnAgentCreatedWorkspaceCantDispatch() async throws {
        let (_, callerId) = try await makeRepository()
        let childId = try await createWorkspace("child", as: callerId)
        let grandchildId = try await createWorkspace("grandchild", as: childId)
        let sibling = try attachChat(to: try await createWorkspace("sibling", as: callerId))

        let (started, startFailed) = try await call("start_session", ["workspace_id": .string(grandchildId), "prompt": "Go"], as: childId)
        XCTAssertTrue(startFailed)
        XCTAssertTrue(started.string?.contains("Only sessions the user started") == true, "\(started)")
        XCTAssertTrue(engine.workspaceState(for: grandchildId).chats.isEmpty)

        let (sent, sendFailed) = try await call("send_message", ["session_ids": [.string(sibling.id)], "text": "Hi"], as: childId)
        XCTAssertTrue(sendFailed)
        XCTAssertTrue(sent.string?.contains("Only sessions the user started") == true, "\(sent)")
        XCTAssertTrue(sibling.turns.isEmpty)
    }

    func testWaitingOnAnUnknownSessionFails() async throws {
        let (_, callerId) = try await makeRepository()
        let (reply, isError) = try await call("wait_for_sessions", ["session_ids": ["nope"], "timeout_seconds": 1], as: callerId)
        XCTAssertTrue(isError)
        XCTAssertTrue(reply.string?.contains("No open session nope") == true, "\(reply)")
    }

    // MARK: Reports

    func testATurnReportsItsTopLevelReplyAndWhatItTouched() {
        let turn = ChatTurn(id: "t1", seq: 4, status: .completed)
        let items: [AgentItem] = [
            AgentItem(id: "u", status: .completed, content: .userMessage(.init(text: "Add a settings screen"))),
            AgentItem(id: "a1", status: .completed, content: .assistantMessage(text: "Looking around first.")),
            AgentItem(id: "c1", status: .completed, content: .command(.init(command: "swift test", exitCode: 1))),
            AgentItem(id: "c2", status: .completed, content: .command(.init(command: "ls", exitCode: 0))),
            AgentItem(id: "f1", status: .completed, content: .fileChange(.init(edits: [
                .init(path: "Settings.swift", kind: .add),
                .init(path: "App.swift", kind: .update)
            ]))),
            AgentItem(id: "f2", status: .completed, content: .fileChange(.init(edits: [.init(path: "Settings.swift", kind: .update)]))),
            AgentItem(id: "a2", status: .completed, content: .assistantMessage(text: "Done: the screen is in Settings.swift.")),
            AgentItem(id: "s1", parentId: "task-1", status: .completed, content: .assistantMessage(text: "Subagent chatter"))
        ]
        turn.items = items.map { ChatItemBox(id: $0.id, item: $0) }

        let report = AgentSessionReport.turn(turn)
        XCTAssertEqual(report["turn"], .int(4))
        XCTAssertEqual(report["status"]?.string, "completed")
        XCTAssertEqual(report["prompt"]?.string, "Add a settings screen")
        XCTAssertEqual(report["reply"]?.string, "Done: the screen is in Settings.swift.", "the last top-level reply, not a subagent's")
        XCTAssertEqual(report["files_changed"]?.array?.compactMap(\.string), ["Settings.swift", "App.swift"])
        XCTAssertEqual(report["commands_run"], .int(2))
        XCTAssertEqual(report["failed_commands"]?.array?.compactMap(\.string), ["swift test"])
        XCTAssertEqual(report["error"], .null)
    }

    func testRequestsSayWhatTheUserIsAsked() {
        let approval = AgentRequest(id: "r1", kind: .approval(.init(
            category: .command, title: "Run rm -rf build", detail: "rm -rf build", reason: nil, allowsSessionScope: true
        )))
        XCTAssertEqual(AgentSessionReport.request(approval)["kind"]?.string, "approval")
        XCTAssertEqual(AgentSessionReport.request(approval)["detail"]?.string, "rm -rf build")

        let questions = AgentRequest(id: "r2", kind: .questions([.init(
            id: "q", header: nil, prompt: "Which database?", options: [], allowsMultiple: false, allowsFreeform: true
        )]))
        XCTAssertEqual(AgentSessionReport.request(questions)["questions"]?.array?.compactMap(\.string), ["Which database?"])
    }

    func testLongTextsAreCutAndSaySo() {
        XCTAssertEqual(AgentSessionReport.head("short", maxLength: 10), "short")
        XCTAssertEqual(AgentSessionReport.head("abcdefghij", maxLength: 4), "abcd… [6 more characters]")
        XCTAssertEqual(AgentSessionReport.tail("abcdefghij", maxLength: 4), "[6 earlier characters] …ghij")
    }
}
