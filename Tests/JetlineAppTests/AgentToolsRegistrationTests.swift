import XCTest
@testable import JetlineApp

/// Registering Jetline's MCP server with the agent CLIs the user runs
/// themselves, so their sessions get the tools without any setup.
final class AgentToolsRegistrationTests: XCTestCase {
    private let server = AgentToolsRegistration.Server(command: "/home/u/.jetline/bin/jetline", args: ["daemon", "mcp"])

    // MARK: Claude Code

    func testClaudeEntryIsAddedOnce() {
        let config: JSONValue = ["mcpServers": ["other": ["command": "x"]]]
        XCTAssertEqual(AgentToolsRegistration.claudeAction(config: config, desired: server, registeredBefore: false), .add)
        XCTAssertEqual(AgentToolsRegistration.claudeAction(config: [:], desired: server, registeredBefore: false), .add)
    }

    func testClaudeEntryTheUserRemovedStaysRemoved() {
        XCTAssertEqual(AgentToolsRegistration.claudeAction(config: [:], desired: server, registeredBefore: true), .none)
    }

    func testClaudeEntryIsLeftAloneWhenCurrent() {
        let config: JSONValue = ["mcpServers": ["jetline": [
            "type": "stdio", "command": .string(server.command), "args": ["daemon", "mcp"], "env": [:]
        ]]]
        XCTAssertEqual(AgentToolsRegistration.claudeAction(config: config, desired: server, registeredBefore: true), .none)
    }

    func testClaudeEntryIsReplacedWhenStale() {
        let config: JSONValue = ["mcpServers": ["jetline": ["type": "stdio", "command": "/old/jetline", "args": ["mcp"]]]]
        XCTAssertEqual(AgentToolsRegistration.claudeAction(config: config, desired: server, registeredBefore: true), .replace)
    }

    func testClaudeJSONIsAStdioServer() throws {
        let json = try JSONValue.parse(Data(server.claudeJSON.utf8))
        XCTAssertEqual(json["type"]?.string, "stdio")
        XCTAssertEqual(json["command"]?.string, server.command)
        XCTAssertEqual(json["args"]?.array?.compactMap(\.string), ["daemon", "mcp"])
    }

    // MARK: Codex

    func testCodexTableIsAppendedKeepingTheRest() throws {
        let toml = "model = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\"\n"
        let updated = try XCTUnwrap(AgentToolsRegistration.codexConfig(toml, desired: server, registeredBefore: false))
        XCTAssertTrue(updated.hasPrefix(toml))
        XCTAssertTrue(updated.contains("[mcp_servers.jetline]\ncommand = \"/home/u/.jetline/bin/jetline\"\nargs = [\"daemon\", \"mcp\"]\n"))
        XCTAssertTrue(updated.contains("default_tools_approval_mode = \"writes\""))
        XCTAssertTrue(updated.contains("tool_timeout_sec = \(AgentTools.maxWaitSeconds + 30)"))
    }

    func testCodexTableIsReplacedWithItsSubtablesButNothingAfter() throws {
        let toml = """
        [mcp_servers.jetline]
        command = "/old/jetline"
        args = ["mcp"]

        [mcp_servers.jetline.env]
        A = "1"

        [profiles.fast]
        model = "o4-mini"

        """
        let updated = try XCTUnwrap(AgentToolsRegistration.codexConfig(toml, desired: server, registeredBefore: true))
        XCTAssertFalse(updated.contains("/old/jetline"))
        XCTAssertFalse(updated.contains("[mcp_servers.jetline.env]"))
        XCTAssertTrue(updated.contains("[profiles.fast]\nmodel = \"o4-mini\""))
        XCTAssertNil(AgentToolsRegistration.codexConfig(updated, desired: server, registeredBefore: true), "already current")
    }

    func testCodexTableTheUserRemovedStaysRemoved() {
        XCTAssertNil(AgentToolsRegistration.codexConfig("model = \"o3\"\n", desired: server, registeredBefore: true))
    }

    func testCodexOverridesAndTableShareTheirSettings() {
        let launch = AgentToolsLaunch(socketPath: "/s.sock", workspaceId: "ws")
        for (key, value) in AgentToolsLaunch.codexServerSettings {
            XCTAssertTrue(launch.args(for: .codex).contains("mcp_servers.jetline.\(key)=\(value)"))
        }
    }

    // MARK: Stable command

    func testTheCommandIsALinkInTheDataDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = try AgentToolsRegistration.linkExecutable("/Applications/Jetline.app/Contents/MacOS/jetline", dataDir: dir)
        XCTAssertEqual(link, dir.appendingPathComponent("bin/jetline").path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "/Applications/Jetline.app/Contents/MacOS/jetline")

        _ = try AgentToolsRegistration.linkExecutable("/opt/Jetline.app/Contents/MacOS/jetline", dataDir: dir)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "/opt/Jetline.app/Contents/MacOS/jetline", "repointed")
    }
}
