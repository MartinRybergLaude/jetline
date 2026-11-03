import XCTest
@testable import JetlineApp

/// How `jetlined mcp` finds out who it's serving when the user started the
/// agent themselves, in a terminal Jetline didn't launch it into.
@MainActor
final class AgentToolsCallerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = TestSupport.dataDir
    }

    // MARK: Engine: workspace for a path

    func testAPathInsideAWorktreeResolvesToItsWorkspace() async throws {
        let engine = Engine()
        let repo = try await engine.addRepository(path: try await TestSupport.makeRepo())
        let baseId = engine.repositoryBaseWorkspaceId(for: repo)
        let created = await engine.runAgentTool("create_workspace", arguments: ["name": "child"], callerId: baseId)
        XCTAssertFalse(created.isError, created.text)
        let child = try XCTUnwrap(JSONValue.parse(Data(created.text.utf8))["id"]?.string)
        let childPath = try XCTUnwrap(engine.workspaceById(child)?.worktreePath)

        XCTAssertEqual(engine.workspaceId(containingPath: repo.path), baseId)
        XCTAssertEqual(engine.workspaceId(containingPath: childPath), child)
        let sub = (childPath as NSString).appendingPathComponent("Sources/deep")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        XCTAssertEqual(engine.workspaceId(containingPath: sub), child, "a subdirectory belongs to the worktree")
        XCTAssertNil(engine.workspaceId(containingPath: childPath + "-sibling"), "a shared prefix isn't containment")
        XCTAssertNil(engine.workspaceId(containingPath: NSTemporaryDirectory()))
    }

    func testTerminalsCarryTheEngineSocketAndTheirWorkspace() {
        let engine = Engine()
        XCTAssertEqual(engine.agentTerminalEnvironment(for: "ws-1"), [:], "no socket, nothing to point at")
        engine.agentToolsSocket = "/s/app.sock"
        XCTAssertEqual(engine.agentTerminalEnvironment(for: "ws-1"), [
            AgentToolsLaunch.socketEnvKey: "/s/app.sock",
            AgentToolsLaunch.workspaceEnvKey: "ws-1"
        ])
    }

    // MARK: Caller resolution

    func testTheWorkingDirectoryWinsOverTheEnvironment() {
        let env = [AgentToolsLaunch.socketEnvKey: "/s/env.sock", AgentToolsLaunch.workspaceEnvKey: "ws-env"]
        let caller = AgentToolsCaller.resolve(cwd: "/w/b", env: env, sockets: ["/s/env.sock", "/s/app.sock"]) { socket, path in
            socket == "/s/app.sock" && path == "/w/b" ? "ws-b" : nil
        }
        XCTAssertEqual(caller, AgentToolsCaller(socketPath: "/s/app.sock", workspaceId: "ws-b"))
    }

    func testFallsBackToTheEnvironmentOutsideAnyWorktree() {
        let env = [AgentToolsLaunch.socketEnvKey: "/s/env.sock", AgentToolsLaunch.workspaceEnvKey: "ws-env"]
        let caller = AgentToolsCaller.resolve(cwd: "/tmp", env: env, sockets: ["/s/env.sock"]) { _, _ in nil }
        XCTAssertEqual(caller, AgentToolsCaller(socketPath: "/s/env.sock", workspaceId: "ws-env"))
    }

    func testNoCallerOutsideJetline() {
        XCTAssertNil(AgentToolsCaller.resolve(cwd: "/tmp", env: [:], sockets: ["/s/app.sock"]) { _, _ in nil })
    }

    func testCandidateSocketsPutTheEnvironmentsFirstWithoutDuplicates() {
        let app = JetlineDaemon.socketPath(named: "jetline-app")
        let daemon = JetlineDaemon.socketPath(named: "jetlined")
        XCTAssertEqual(AgentToolsCaller.candidateSockets(env: [:]), [app, daemon])
        XCTAssertEqual(AgentToolsCaller.candidateSockets(env: [AgentToolsLaunch.socketEnvKey: "/s/x.sock"]), ["/s/x.sock", app, daemon])
        XCTAssertEqual(AgentToolsCaller.candidateSockets(env: [AgentToolsLaunch.socketEnvKey: daemon]), [daemon, app])
    }

    // MARK: MCP replies

    func testOutsideAWorkspaceTheServerListsNoTools() throws {
        let listed = try XCTUnwrap(AgentToolsServer.reply(to: request("tools/list"), caller: nil) { _, _ in
            XCTFail("no call without a caller")
            return API.AgentToolResult(text: "", isError: true)
        })
        XCTAssertEqual(listed["result"]?["tools"]?.array?.count, 0)

        let called = try XCTUnwrap(AgentToolsServer.reply(to: request("tools/call", ["name": "get_context"]), caller: nil) { _, _ in
            API.AgentToolResult(text: "", isError: false)
        })
        XCTAssertEqual(called["result"]?["isError"]?.bool, true)
    }

    func testInsideAWorkspaceTheServerListsAndRelaysEveryTool() throws {
        let caller = AgentToolsCaller(socketPath: "/s/app.sock", workspaceId: "ws-1")
        let listed = try XCTUnwrap(AgentToolsServer.reply(to: request("tools/list"), caller: caller) { _, _ in
            API.AgentToolResult(text: "", isError: true)
        })
        XCTAssertEqual(listed["result"]?["tools"]?.array?.count, AgentTools.catalog.count)

        var relayed: String?
        let called = try XCTUnwrap(AgentToolsServer.reply(to: request("tools/call", ["name": "get_context"]), caller: caller) { name, _ in
            relayed = name
            return API.AgentToolResult(text: "{}", isError: false)
        })
        XCTAssertEqual(relayed, "get_context")
        XCTAssertEqual(called["result"]?["isError"]?.bool, false)
    }

    func testNotificationsGetNoReply() {
        let note: JSONValue = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        XCTAssertNil(AgentToolsServer.reply(to: note, caller: nil) { _, _ in API.AgentToolResult(text: "", isError: true) })
    }

    private func request(_ method: String, _ params: JSONValue = [:]) -> JSONValue {
        ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
    }
}
