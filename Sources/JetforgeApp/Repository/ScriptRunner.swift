import Foundation

/// One-shot shell script runner. Used for setup and archive scripts where
/// we want a synchronous result (success/failure + captured output) rather
/// than a long-running process the user controls.
///
/// We invoke through `/bin/zsh -lc` so the user's PATH (Homebrew, asdf,
/// nvm) is loaded — same reasoning as `AgentLauncher.shellCommand`.
enum ScriptRunner {
    /// Env var pointing at the original repo path. Setup/run/archive scripts
    /// can read it to copy or symlink files (e.g. `.env`).
    static let rootPathEnvKey = "JETFORGE_ROOT_PATH"

    /// Standard env every script gets — repo root path under our well-known key.
    static func defaultEnv(repoPath: String) -> [String: String] {
        [rootPathEnvKey: repoPath]
    }

    struct Result: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
        var success: Bool { status == 0 }
    }

    /// Run `script` with the given working directory and extra environment.
    /// Returns the captured output. Skips silently for blank scripts.
    static func run(
        _ script: String,
        cwd: String,
        env: [String: String] = [:],
        timeout: TimeInterval? = nil
    ) async -> Result? {
        guard let trimmed = script.nonBlank else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(trimmed, cwd: cwd, env: env, timeout: timeout))
            }
        }
    }

    private static func runSync(
        _ script: String,
        cwd: String,
        env: [String: String],
        timeout: TimeInterval?
    ) -> Result {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", script]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "spawn failed: \(error)", status: -1)
        }

        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: killer)
            process.waitUntilExit()
            killer.cancel()
        } else {
            process.waitUntilExit()
        }

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
