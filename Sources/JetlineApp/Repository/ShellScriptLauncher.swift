import Foundation

/// Builds the shell invocation used for user-authored repository scripts.
///
/// Jetline's visible terminal starts the user's login shell on a PTY, so zsh
/// users get `.zprofile` and `.zshrc`. Running scripts as `SHELL -lc` only
/// loaded the login/profile side and skipped rc-file setup such as nvm, mise,
/// aliases, exported SDK variables, and prompt-adjacent helper functions.
/// `-lic` matches the interactive login startup path while still executing
/// the configured script via `-c`.
enum ShellScriptLauncher {
    static var shell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    static func args(for script: String) -> [String] {
        ["-lic", script]
    }
}
