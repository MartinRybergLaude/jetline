import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `jetlined mcp`: the MCP server (stdio, newline-delimited JSON-RPC) that
/// gives an agent Jetline's tools. Jetline launches it for each agent with
/// the engine's socket and the agent's workspace in its environment; every
/// tool call is relayed to the engine, which decides what the caller may do.
enum AgentToolsServer {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let env = ProcessInfo.processInfo.environment
        guard let socket = env[AgentToolsLaunch.socketEnvKey]?.nonBlank,
              let workspaceId = env[AgentToolsLaunch.workspaceEnvKey]?.nonBlank else {
            FileHandle.standardError.write(Data("jetlined mcp: run by Jetline for an agent; \(AgentToolsLaunch.socketEnvKey) and \(AgentToolsLaunch.workspaceEnvKey) aren't set\n".utf8))
            exit(1)
        }
        let link = EngineLink(socketPath: socket)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8), !data.isEmpty,
                  let message = try? JSONValue.parse(data) else { continue }
            // Notifications (no id) need no answer.
            guard let id = message["id"], !id.isNull else { continue }
            let reply: JSONValue
            switch message["method"]?.string {
            case "initialize":
                reply = result(id, [
                    "protocolVersion": message["params"]?["protocolVersion"] ?? "2025-06-18",
                    "capabilities": ["tools": .object([:])],
                    "serverInfo": ["name": .string(AgentTools.serverName), "version": .string(JetlineVersion.current)],
                    "instructions": .string(instructions)
                ])
            case "ping":
                reply = result(id, [:])
            case "tools/list":
                reply = result(id, ["tools": .array(AgentTools.catalog.map(describe))])
            case "tools/call":
                let name = message["params"]?["name"]?.string ?? ""
                let arguments = message["params"]?["arguments"] ?? .object([:])
                let outcome = link.callTool(name, arguments: arguments, workspaceId: workspaceId)
                reply = result(id, [
                    "content": .array([.object(["type": "text", "text": .string(outcome.text)])]),
                    "isError": .bool(outcome.isError)
                ])
            default:
                reply = .object([
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": ["code": -32601, "message": .string("Unknown method \(message["method"]?.string ?? "")")]
                ])
            }
            var out = reply.serialized()
            out.append(0x0A)
            FileHandle.standardOutput.write(out)
        }
        exit(0)
    }

    private static let instructions = """
    Jetline manages this repository's worktrees ("workspaces") and shows them in the user's sidebar. \
    Use these tools instead of `git worktree` or `git checkout -b` when work should live on its own \
    branch: stack a new workspace on yours for a follow-up that should be its own pull request, or \
    create one off the default branch for unrelated work. You keep working where you are; nothing \
    runs in a workspace you create, so leave a note saying what it's for. When the work spans another \
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
