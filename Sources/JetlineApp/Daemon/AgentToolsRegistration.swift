import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Registers `jetlined mcp` in Claude Code's and Codex's user config each
/// time an engine starts, so a session the user starts themselves (`claude`
/// typed into a terminal) gets Jetline's tools with no setup. The server
/// finds its workspace from the session's directory and serves nothing
/// outside Jetline's worktrees.
///
/// The command is a link in the data directory, repointed at whichever
/// build last started, so updating or moving the app leaves the agents'
/// config alone. An entry the user deletes stays deleted: each CLI is
/// registered once, and only kept current after that.
enum AgentToolsRegistration {
    struct Server: Equatable, Sendable {
        var command: String
        var args: [String]

        var claudeJSON: String {
            JSONValue.object([
                "type": "stdio",
                "command": .string(command),
                "args": .array(args.map(JSONValue.string))
            ]).serializedString()
        }

        var codexTable: String {
            let lines = ["[\(codexTableName)]", "command = \(AgentToolsLaunch.toml(command))", "args = \(AgentToolsLaunch.toml(args))"]
                + AgentToolsLaunch.codexServerSettings.map { "\($0.key) = \($0.value)" }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    enum Action: Equatable {
        case none, add, replace
    }

    private static let codexTableName = "mcp_servers.\(AgentTools.serverName)"
    private static let markerFile = "agent-tools-registered"

    // MARK: Start

    /// Link this executable and register it, in the background. Skipped
    /// under a custom `JETLINE_DATA_DIR` (tests, a second dev instance), so
    /// those never repoint the user's config.
    static func registerInBackground(log: @escaping @Sendable (String) -> Void) {
        guard ProcessInfo.processInfo.environment["JETLINE_DATA_DIR"]?.nonBlank == nil,
              let executable = JetlineDaemon.currentExecutable() else { return }
        let args = JetlineDaemon.commandPrefix + ["mcp"]
        Task.detached(priority: .utility) {
            let dataDir = Database.dataDirectory()
            do {
                let server = Server(command: try linkExecutable(executable, dataDir: dataDir), args: args)
                await registerWithClaude(server, dataDir: dataDir, log: log)
                try registerWithCodex(server, dataDir: dataDir, log: log)
            } catch {
                log("Couldn't give agents started outside Jetline its tools: \(error.localizedDescription)")
            }
        }
    }

    /// `<data dir>/bin/jetline`, pointing at `executable`. Swapped in with a
    /// rename, so a session starting meanwhile never finds it missing.
    static func linkExecutable(_ executable: String, dataDir: URL) throws -> String {
        let bin = dataDir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("jetline").path
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == executable { return link }
        let staging = "\(link).\(getpid())"
        try? FileManager.default.removeItem(atPath: staging)
        try FileManager.default.createSymbolicLink(atPath: staging, withDestinationPath: executable)
        guard rename(staging, link) == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(atPath: staging)
            throw JetlineDaemon.DaemonError("can't link \(link): \(reason)")
        }
        return link
    }

    // MARK: Claude Code

    static func claudeAction(config: JSONValue, desired: Server, registeredBefore: Bool) -> Action {
        guard let entry = config["mcpServers"]?[AgentTools.serverName] else {
            return registeredBefore ? .none : .add
        }
        let current = Server(command: entry["command"]?.string ?? "", args: entry["args"]?.array?.compactMap(\.string) ?? [])
        return current == desired ? .none : .replace
    }

    /// Through the `claude mcp` commands: Claude Code rewrites its config
    /// file while running, so editing it here could lose a write.
    private static func registerWithClaude(_ server: Server, dataDir: URL, log: @Sendable (String) -> Void) async {
        // No config: Claude Code isn't set up on this machine.
        guard let data = try? Data(contentsOf: ClaudeProvider.userConfigFile),
              let config = try? JSONValue.parse(data) else { return }
        let marked = registered(dataDir).contains("claude")
        let action = claudeAction(config: config, desired: server, registeredBefore: marked)
        if action == .none {
            // Already there (from an earlier Jetline): from now on, a removal sticks.
            if !marked, config["mcpServers"]?[AgentTools.serverName] != nil { markRegistered("claude", dataDir: dataDir, log: log) }
            return
        }
        guard let claude = await AgentLauncher.resolveOnPath("claude") else { return }
        let name = AgentTools.serverName
        if action == .replace {
            _ = await Subprocess.run(executable: claude, args: ["mcp", "remove", "--scope", "user", name], closeStdin: true, timeout: 30)
        }
        let added = await Subprocess.run(
            executable: claude,
            args: ["mcp", "add-json", "--scope", "user", name, server.claudeJSON],
            closeStdin: true,
            timeout: 30
        )
        guard added.success else {
            log("Couldn't register Jetline's tools with Claude Code: \(added.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            return
        }
        markRegistered("claude", dataDir: dataDir, log: log)
    }

    // MARK: Codex

    /// `toml` with the `[mcp_servers.jetline]` table (and its subtables)
    /// made `desired`'s, or `nil` when there's nothing to write.
    static func codexConfig(_ toml: String, desired: Server, registeredBefore: Bool) -> String? {
        let lines = toml.components(separatedBy: "\n")
        let header = "[\(codexTableName)]"
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            if registeredBefore { return nil }
            let separator = toml.isEmpty || toml.hasSuffix("\n\n") ? "" : toml.hasSuffix("\n") ? "\n" : "\n\n"
            return toml + separator + desired.codexTable
        }
        let end = lines[(start + 1)...].firstIndex { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("[") && !trimmed.hasPrefix("[\(codexTableName).")
        } ?? lines.endIndex
        let current = lines[start..<end].joined(separator: "\n")
        let table = desired.codexTable.trimmingCharacters(in: .newlines)
        guard current.trimmingCharacters(in: .whitespacesAndNewlines) != table else { return nil }
        let replacement = table.components(separatedBy: "\n") + (end < lines.endIndex ? [""] : [])
        return (Array(lines[..<start]) + replacement + Array(lines[end...])).joined(separator: "\n")
    }

    /// Codex reads its config at startup only, so an atomic write is safe.
    private static func registerWithCodex(_ server: Server, dataDir: URL, log: @Sendable (String) -> Void) throws {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]?.nonBlank.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        // No directory: Codex isn't set up on this machine.
        guard FileManager.default.fileExists(atPath: home.path) else { return }
        let file = home.appendingPathComponent("config.toml")
        let toml = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let marked = registered(dataDir).contains("codex")
        guard let updated = codexConfig(toml, desired: server, registeredBefore: marked) else {
            if !marked, toml.contains("[\(codexTableName)]") { markRegistered("codex", dataDir: dataDir, log: log) }
            return
        }
        try updated.write(to: file, atomically: true, encoding: .utf8)
        markRegistered("codex", dataDir: dataDir, log: log)
    }

    // MARK: Markers

    private static func registered(_ dataDir: URL) -> Set<String> {
        let text = (try? String(contentsOf: dataDir.appendingPathComponent(markerFile), encoding: .utf8)) ?? ""
        return Set(text.split(separator: "\n").map(String.init))
    }

    private static func markRegistered(_ cli: String, dataDir: URL, log: @Sendable (String) -> Void) {
        let names = registered(dataDir).union([cli]).sorted()
        do {
            try (names.joined(separator: "\n") + "\n").write(to: dataDir.appendingPathComponent(markerFile), atomically: true, encoding: .utf8)
        } catch {
            log("Couldn't record that Jetline's tools are registered with \(cli): \(error.localizedDescription)")
        }
    }
}
