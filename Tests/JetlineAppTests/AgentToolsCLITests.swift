import XCTest
@testable import JetlineApp

/// `jetline <tool> [--flag value …]`: the agent tools from a shell.
final class AgentToolsCLITests: XCTestCase {
    // MARK: Commands

    func testToolsAreNamedInKebabOrSnakeCase() {
        XCTAssertEqual(AgentToolsCLI.tool(named: "list-workspaces")?.name, "list_workspaces")
        XCTAssertEqual(AgentToolsCLI.tool(named: "list_workspaces")?.name, "list_workspaces")
        XCTAssertNil(AgentToolsCLI.tool(named: "merge-workspace"))
    }

    func testHandlesToolsButNotDaemonCommands() {
        XCTAssertTrue(AgentToolsCLI.handles("tools"))
        XCTAssertTrue(AgentToolsCLI.handles("get-context"))
        for command in ["serve", "attach", "status", "stop", "rpc", "mcp", "version", "info", "help", "-NSDocumentRevisionsDebugMode"] {
            XCTAssertFalse(AgentToolsCLI.handles(command), command)
        }
    }

    // MARK: Arguments

    func testFlagsFollowTheSchema() throws {
        let tool = try XCTUnwrap(AgentToolsCLI.tool(named: "import-branch"))
        let args = try AgentToolsCLI.arguments(for: tool, from: ["--pull-request", "42", "--name=fix-login", "--repository", "web"])
        XCTAssertEqual(args, ["pull_request": 42, "name": "fix-login", "repository": "web"])
    }

    func testArraysRepeatTheirFlag() throws {
        let tool = try XCTUnwrap(AgentToolsCLI.tool(named: "send-message"))
        let args = try AgentToolsCLI.arguments(for: tool, from: ["--session-ids", "a", "--session-ids", "b", "--text", "go"])
        XCTAssertEqual(args, ["session_ids": ["a", "b"], "text": "go"])
    }

    func testPositionalValuesFillRequiredProperties() throws {
        let tool = try XCTUnwrap(AgentToolsCLI.tool(named: "create-workspace"))
        XCTAssertEqual(try AgentToolsCLI.arguments(for: tool, from: ["settings-screen"])["name"], "settings-screen")
    }

    func testJSONIsTheBaseFlagsOverride() throws {
        let tool = try XCTUnwrap(AgentToolsCLI.tool(named: "create-workspace"))
        let args = try AgentToolsCLI.arguments(for: tool, from: ["--json", #"{"name":"a","note":"n"}"#, "--name", "b"])
        XCTAssertEqual(args, ["name": "b", "note": "n"])
    }

    func testMistakesAreCaughtBeforeCallingJetline() throws {
        let create = try XCTUnwrap(AgentToolsCLI.tool(named: "create-workspace"))
        XCTAssertThrowsError(try AgentToolsCLI.arguments(for: create, from: ["--nmae", "x"])) { error in
            XCTAssertTrue("\(error)".contains("--nmae"))
        }
        XCTAssertThrowsError(try AgentToolsCLI.arguments(for: create, from: [])) { error in
            XCTAssertTrue("\(error)".contains("--name"))
        }
        XCTAssertThrowsError(try AgentToolsCLI.arguments(for: create, from: ["--name"]))
        let importBranch = try XCTUnwrap(AgentToolsCLI.tool(named: "import-branch"))
        XCTAssertThrowsError(try AgentToolsCLI.arguments(for: importBranch, from: ["--pull-request", "abc"]))
    }

    // MARK: Help

    func testToolHelpListsItsFlags() throws {
        let help = AgentToolsCLI.usage(for: try XCTUnwrap(AgentToolsCLI.tool(named: "create-workspace")))
        XCTAssertTrue(help.hasPrefix("usage: jetline create-workspace <name>"))
        XCTAssertTrue(help.contains("--stack-on"))
        XCTAssertTrue(AgentToolsCLI.overview.contains("rebase-workspace"))
    }

    // MARK: PATH

    func testTerminalsFindTheCommandFirst() {
        XCTAssertEqual(AgentToolsCLI.prependingBin("/d/bin", to: ["PATH": "/usr/bin:/bin"])["PATH"], "/d/bin:/usr/bin:/bin")
        XCTAssertEqual(AgentToolsCLI.prependingBin("/d/bin", to: ["PATH": "/d/bin:/usr/bin"])["PATH"], "/d/bin:/usr/bin", "once")
        XCTAssertEqual(AgentToolsCLI.prependingBin("/d/bin", to: [:])["PATH"], "/d/bin")
    }
}
