import Foundation

/// Resolves agent CLI executable paths and constructs spawn arguments.
enum AgentLauncher {
    struct Spec {
        var executable: String
        var args: [String]
        var env: [String: String]
        /// True if we couldn't find the agent CLI and fell back to a plain shell.
        /// The UI surfaces this so the user can install / configure the binary.
        var fellBackToShell: Bool
    }

    /// Build a spawn spec for the given agent. Honours user-configured paths;
    /// otherwise resolves via several PATH probes; finally falls back to the
    /// user's login shell so the terminal is always usable.
    ///
    /// `sessionId` is Jetline's session UUID. Claude accepts `--session-id` at
    /// first launch and `--resume` thereafter, so we get true per-tab resume.
    /// Codex and Vibe have no flag to seed a session ID at start, so on resume
    /// we use their built-in "most recent in cwd" flags (`resume --last` /
    /// `-c`) — multiple tabs of those agents in the same workspace can't all
    /// be resumed, and the caller must collapse duplicates before getting here.
    ///
    /// `initialPrompt`, when set, is appended as a positional argument so the
    /// agent boots straight into a task. Always passed to fresh sessions only;
    /// a resumed conversation already has its own history. Ignored for
    /// `.shell` (the shell can't act on a prompt autonomously).
    static func spec(
        for agent: Workspace.AgentKind,
        settings: AppSettings,
        sessionId: String,
        isResume: Bool,
        initialPrompt: String? = nil
    ) async throws -> Spec {
        // Plain terminal: skip resolution, just open the user's login shell.
        if agent == .shell {
            return Spec(
                executable: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                args: ["-l"],
                env: agentEnv(),
                fellBackToShell: false
            )
        }

        let configured: String? = {
            switch agent {
            case .claude: return settings.claudeBinaryPath
            case .codex: return settings.codexBinaryPath
            case .vibe: return settings.mistralBinaryPath
            case .shell: return nil
            }
        }()

        var args = resumeArgs(for: agent, sessionId: sessionId, isResume: isResume)
        if !isResume, let prompt = initialPrompt?.nonBlank {
            args.append(prompt)
        }

        if let configured, !configured.isEmpty,
           FileManager.default.isExecutableFile(atPath: configured) {
            return Spec(
                executable: configured,
                args: args,
                env: agentEnv(),
                fellBackToShell: false
            )
        }

        if let resolved = await resolveOnPath(agent.executableName) {
            return Spec(
                executable: resolved,
                args: args,
                env: agentEnv(),
                fellBackToShell: false
            )
        }

        // Fall back to the user's login shell so the terminal is at least usable
        // and they can debug from inside it. Higher-level UI shows a banner.
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return Spec(
            executable: shellPath,
            args: ["-l"],
            env: agentEnv(),
            fellBackToShell: true
        )
    }

    private static func agentEnv() -> [String: String] {
        ["JETLINE": "1"]
    }

    /// Only Claude supports per-tab resume — `--session-id` lets us seed the
    /// conversation with our own UUID at first launch and `--resume` reattaches
    /// to it later. Codex and Vibe only offer "most recent in cwd" flags, which
    /// can latch onto the wrong conversation when multiple workspaces share
    /// state, so we deliberately don't try.
    private static func resumeArgs(
        for agent: Workspace.AgentKind,
        sessionId: String,
        isResume: Bool
    ) -> [String] {
        guard agent == .claude else { return [] }
        return isResume ? ["--resume", sessionId] : ["--session-id", sessionId]
    }

    /// Try several strategies to find a CLI on disk. App bundles launched from
    /// Finder don't inherit the user's shell PATH, so `which foo` from inside
    /// the bundle won't see Homebrew/asdf/nvm-installed binaries.
    static func resolveOnPath(_ name: String) async -> String? {
        // 1. Cheap candidates that cover ~95% of installs.
        let candidates = bundledCandidatePaths(for: name)
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // 2. Ask a non-interactive login shell. `-l` runs profile/.zprofile so
        // PATH is augmented with /opt/homebrew, ~/.local/bin, asdf shims, etc.
        // Avoids `-i` which can hang on prompts that read stdin.
        if let resolved = await shellCommand(name) {
            return resolved
        }

        return nil
    }

    private static func bundledCandidatePaths(for name: String) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
            "\(home)/.cargo/bin/\(name)"
        ]
    }

    /// Run `command -v <name>` inside a non-interactive login shell.
    /// Bounded with a hard timeout so a misbehaving shell can't hang the app.
    private static func shellCommand(_ name: String) async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-l", "-c", "command -v \(name)"]

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = Pipe()
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                // Hard timeout: 4 seconds. Some user .zprofile setups can stall.
                let deadline = DispatchTime.now() + .seconds(4)
                let killer = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)

                process.waitUntilExit()
                killer.cancel()

                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let trimmed = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }
}
