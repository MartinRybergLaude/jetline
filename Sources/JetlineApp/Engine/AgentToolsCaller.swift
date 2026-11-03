import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whom a `jetlined mcp` serves: an engine to relay tool calls to, and the
/// workspace they're made from.
///
/// Jetline tells the agents it launches through the environment. An agent
/// the user starts themselves (`claude` typed into a terminal) has only its
/// working directory to go on, so the workspace whose worktree holds it is
/// asked of each engine on this machine. That wins over the environment
/// too: a shell can `cd` into another worktree after Jetline opened it.
struct AgentToolsCaller: Sendable, Equatable {
    var socketPath: String
    var workspaceId: String

    /// The first engine in `sockets` that knows a workspace holding `cwd`,
    /// else the environment's caller, else none: not run in Jetline.
    static func resolve(
        cwd: String,
        env: [String: String],
        sockets: [String],
        lookup: (_ socketPath: String, _ path: String) -> String?
    ) -> AgentToolsCaller? {
        for socket in sockets {
            if let id = lookup(socket, cwd) { return AgentToolsCaller(socketPath: socket, workspaceId: id) }
        }
        guard let socket = env[AgentToolsLaunch.socketEnvKey]?.nonBlank,
              let id = env[AgentToolsLaunch.workspaceEnvKey]?.nonBlank else { return nil }
        return AgentToolsCaller(socketPath: socket, workspaceId: id)
    }

    /// The engine Jetline pointed us at, then the Mac app's, then the daemon's.
    static func candidateSockets(env: [String: String]) -> [String] {
        let known = [JetlineDaemon.socketPath(named: "jetline-app"), JetlineDaemon.socketPath(named: "jetlined")]
        var out: [String] = []
        for socket in [env[AgentToolsLaunch.socketEnvKey]?.nonBlank].compactMap({ $0 }) + known where !out.contains(socket) {
            out.append(socket)
        }
        return out
    }

    /// `resolve` for this process, asking the engines over their sockets.
    static func current() -> AgentToolsCaller? {
        let env = ProcessInfo.processInfo.environment
        let sockets = candidateSockets(env: env).filter { FileManager.default.fileExists(atPath: $0) }
        return resolve(cwd: FileManager.default.currentDirectoryPath, env: env, sockets: sockets) { socket, path in
            guard let client = try? BlockingEngineClient(socketPath: socket, clientName: "jetline mcp"),
                  let reply = try? client.call(API.ResolveAgentWorkspace.method, ["path": .string(path)]) else { return nil }
            return reply["workspaceId"]?.string
        }
    }
}

extension Engine {
    /// The workspace whose worktree holds `path` (the deepest, should one
    /// worktree sit inside another's checkout), or `nil`.
    func workspaceId(containingPath path: String) -> String? {
        let target = Self.canonicalPath(path)
        let candidates = workspacesByRepo.values.flatMap { $0 } + repositories.compactMap { workspaceById(repositoryBaseWorkspaceId(for: $0)) }
        return candidates
            .map { (id: $0.id, root: Self.canonicalPath($0.worktreePath)) }
            .filter { target == $0.root || target.hasPrefix($0.root.hasSuffix("/") ? $0.root : $0.root + "/") }
            .max { $0.root.count < $1.root.count }?
            .id
    }

    /// What every terminal in `workspaceId` gets, so an agent started in it
    /// by hand can still reach this engine as that workspace.
    func agentTerminalEnvironment(for workspaceId: String) -> [String: String] {
        agentToolsLaunch(for: workspaceId)?.env ?? [:]
    }

    /// Symlinks resolved (macOS's /tmp is /private/tmp), so a path from a
    /// shell and one Jetline stored compare equal.
    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
