import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `jetlined mcp`: the MCP server (stdio, newline-delimited JSON-RPC) that
/// gives an agent Jetline's tools. Jetline launches it for each agent with
/// the engine's socket and the agent's workspace in its environment, and
/// registers it with the agent CLIs so a session the user starts by hand
/// gets it too (see `AgentToolsCaller` for how that one finds its
/// workspace). Every tool call is relayed to the engine, which decides what
/// the caller may do. Outside any workspace it serves no tools, so it costs
/// sessions in unrelated projects nothing.
enum AgentToolsServer {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        var caller: AgentToolsCaller?
        var link: EngineLink?
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), !data.isEmpty,
                  let message = try? JSONValue.parse(data) else { continue }
            // Until Jetline knows this directory (it may start after the agent).
            if caller == nil, message["id"].map({ !$0.isNull }) == true {
                caller = AgentToolsCaller.current()
                link = caller.map { EngineLink(socketPath: $0.socketPath) }
            }
            let out = reply(to: message, caller: caller) { name, arguments in
                guard let caller, let link else { return notInWorkspace }
                return link.callTool(name, arguments: arguments, workspaceId: caller.workspaceId)
            }
            guard var bytes = out?.serialized() else { continue }
            bytes.append(0x0A)
            FileHandle.standardOutput.write(bytes)
        }
        exit(0)
    }

    /// The answer to one JSON-RPC message, or `nil` for a notification.
    /// Without a caller there are no tools to list or call.
    static func reply(
        to message: JSONValue,
        caller: AgentToolsCaller?,
        call: (_ tool: String, _ arguments: JSONValue) -> API.AgentToolResult
    ) -> JSONValue? {
        guard let id = message["id"], !id.isNull else { return nil }
        switch message["method"]?.string {
        case "initialize":
            return result(id, [
                "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": .object([:])],
                "serverInfo": ["name": .string(AgentTools.serverName), "version": .string(JetlineVersion.current)],
                "instructions": .string(caller == nil ? notInWorkspace.text : instructions)
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": .array(caller == nil ? [] : AgentTools.catalog.map(describe))])
        case "tools/call":
            let name = message["params"]?["name"]?.string ?? ""
            let arguments = message["params"]?["arguments"] ?? .object([:])
            let outcome = caller == nil ? notInWorkspace : call(name, arguments)
            return result(id, [
                "content": .array([.object(["type": "text", "text": .string(outcome.text)])]),
                "isError": .bool(outcome.isError)
            ])
        default:
            return .object([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": .string("Unknown method \(message["method"]?.string ?? "")")]
            ])
        }
    }

    private static let notInWorkspace = API.AgentToolResult(
        text: "This session isn't in a Jetline workspace, so Jetline's tools are off. They're on for sessions started in a workspace's worktree while Jetline is running.",
        isError: true
    )

    private static let instructions = """
    Jetline manages this repository's worktrees ("workspaces") and shows them in the user's sidebar. \
    Use these tools instead of `git worktree` or `git checkout -b` when work should live on its own \
    branch: stack a new workspace on yours for a follow-up that should be its own pull request, or \
    create one off the default branch for unrelated work. You keep working where you are; nothing \
    runs in a workspace you create until you start_session there, so leave a note saying what it's \
    for. To dispatch work, start a session in each workspace you created with a complete brief, \
    then wait_for_sessions and read_session to follow along, and send_message for follow-ups or \
    instructions shared by several sessions. When the work spans another \
    repository added to Jetline (say, a backend change a frontend feature needs), find it with \
    list_repositories and create the workspace there instead of cloning or editing its checkout. \
    Always give workspaces very short kebab-case names, one to three words, e.g. "settings-screen".
    """

    private static func result(_ id: JSONValue, _ fields: [String: JSONValue]) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": .object(fields)])
    }

    private static func describe(_ tool: AgentTools.Tool) -> JSONValue {
        .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(tool.readOnly),
                "destructiveHint": .bool(tool.rewritesHistory),
                "openWorldHint": .bool(false)
            ])
        ])
    }
}

/// Relays tool calls to the engine, connecting on first use and again
/// after the engine goes away.
private final class EngineLink {
    private let socketPath: String
    private var client: BlockingEngineClient?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func callTool(_ tool: String, arguments: JSONValue, workspaceId: String) -> API.AgentToolResult {
        do {
            let client = try self.client ?? BlockingEngineClient(socketPath: socketPath, clientName: "jetline mcp")
            self.client = client
            let result = try client.call(API.AgentToolCall.method, [
                "workspaceId": .string(workspaceId),
                "tool": .string(tool),
                "arguments": arguments
            ])
            return API.AgentToolResult(text: result["text"]?.string ?? "", isError: result["isError"]?.bool ?? false)
        } catch {
            client = nil
            let reason = error.localizedDescription
            return API.AgentToolResult(text: "\(reason) Jetline's tools are unavailable until it's back.", isError: true)
        }
    }
}
