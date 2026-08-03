import Foundation

/// One-shot shell script runner. Used for setup and archive scripts where
/// we want a synchronous result (success/failure + captured output) rather
/// than a long-running process the user controls.
///
/// We invoke through the user's interactive login shell so scripts see the
/// same startup files as the embedded terminal.
enum ScriptRunner {
    /// Env var pointing at the original repo path. Setup/run/archive scripts
    /// can read it to copy or symlink files (e.g. `.env`).
    static let rootPathEnvKey = "JETLINE_ROOT_PATH"

    /// Standard env every script gets — repo root path under our well-known key.
    static func defaultEnv(repoPath: String) -> [String: String] {
        [rootPathEnvKey: repoPath]
    }

    typealias Result = Subprocess.Result

    /// Run `script` with the given working directory and extra environment.
    /// Returns the captured output. Skips silently for blank scripts.
    static func run(
        _ script: String,
        cwd: String,
        env: [String: String] = [:],
        timeout: TimeInterval? = 300
    ) async -> Result? {
        guard let trimmed = script.nonBlank else { return nil }
        return await Subprocess.run(
            executable: ShellScriptLauncher.shell,
            args: ShellScriptLauncher.args(for: trimmed),
            cwd: cwd,
            env: env,
            closeStdin: true,
            timeout: timeout
        )
    }
}
