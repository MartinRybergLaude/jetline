import XCTest
@testable import JetlineApp

final class AgentToolsTests: XCTestCase {
    private let launch = AgentToolsLaunch(socketPath: "/tmp/x.sock", workspaceId: "ws-1")

    func testClaudeArgsUseEqualsFormsAndPreapproveReads() throws {
        let args = launch.args(for: .claude)
        XCTAssertEqual(args.count, 2)
        let config = try XCTUnwrap(args.first { $0.hasPrefix("--mcp-config=") }?.dropFirst("--mcp-config=".count))
        let parsed = try JSONValue.parse(Data(config.utf8))
        let server = try XCTUnwrap(parsed["mcpServers"]?["jetline"])
        XCTAssertEqual(server["env"]?["JETLINE_WORKSPACE_ID"]?.string, "ws-1")
        XCTAssertEqual(server["env"]?["JETLINE_ENGINE_SOCKET"]?.string, "/tmp/x.sock")
        XCTAssertEqual(
            args.last,
            "--allowedTools=mcp__jetline__get_context,mcp__jetline__list_workspaces,mcp__jetline__get_workspace"
        )
    }

    func testCodexArgsAreTOMLOverrides() {
        let args = launch.args(for: .codex)
        XCTAssertEqual(args.enumerated().filter { $0.offset % 2 == 0 }.map(\.element), Array(repeating: "-c", count: args.count / 2))
        XCTAssertTrue(args.contains("mcp_servers.jetline.default_tools_approval_mode=\"writes\""))
        XCTAssertTrue(args.contains("mcp_servers.jetline.env.JETLINE_WORKSPACE_ID=\"ws-1\""))
    }

    func testOnlyReadsAreReadOnly() {
        XCTAssertEqual(AgentTools.readOnlyToolNames, ["get_context", "list_workspaces", "get_workspace"])
        // No merge, delete or close tools.
        let names = AgentTools.catalog.map(\.name)
        XCTAssertFalse(names.contains { $0.contains("merge") || $0.contains("delete") || $0.contains("close") })
    }
}
