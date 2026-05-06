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
    /// `initialPrompt`, when set, is appended as a positional argument so the
    /// agent boots straight into a task. Ignored for `.shell` (the shell can't
    /// act on a prompt autonomously).
    static func spec(
        for agent: Workspace.AgentKind,
        settings: AppSettings,
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

        var args: [String] = []
        if let prompt = initialPrompt?.nonBlank {
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
    /// Bounded with a hard timeout so a misbehaving shell can't hang the app,
    /// and routed through `Subprocess.run` so its readabilityHandler-based
    /// drain handles the case where shell init spawns a daemon that inherits
    /// fd 1/2 (fsmonitor, gpg-agent, etc.) — otherwise the read end never
    /// sees EOF and the continuation never resumes.
    private static func shellCommand(_ name: String) async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = await Subprocess.run(
            executable: shell,
            args: ["-l", "-c", "command -v \(name)"],
            closeStdin: true,
            timeout: 4
        )
        guard result.success else { return nil }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
