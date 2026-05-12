import Foundation

/// Resolves the user's login-shell PATH once at app launch and caches it.
///
/// macOS apps launched from Launchpad/Finder inherit launchd's minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), which excludes Homebrew, asdf, mise,
/// rbenv, ~/.local/bin, etc. The same app launched via `open Foo.app` from
/// a terminal inherits the shell's PATH instead, so behaviour silently
/// diverges between dev (`make run`) and production launches — git/gh/agent
/// spawns "just work" in dev and fail with "command not found" in prod.
///
/// We run `$SHELL -lc 'printf %s "$PATH"'` once at startup. The login shell
/// sources the user's profile, so the resulting PATH matches what they'd
/// see in their terminal. `Subprocess.run` overlays this PATH onto every
/// spawn, making behaviour consistent regardless of how the app was launched.
enum LoginShellPath {
    /// Awaits resolution and returns the resulting PATH. Callers in async
    /// contexts (e.g. `Subprocess.run`) should use this for correctness —
    /// spawns issued in the first ~300ms after launch otherwise risk seeing
    /// the unresolved inherited PATH via `snapshot()`.
    static func get() async -> String {
        await task.value
    }

    /// Synchronous best-effort accessor. Returns the resolved PATH if ready,
    /// else the inherited PATH (which may be the minimal launchd one).
    /// Safe to call from any thread; never blocks.
    static func snapshot() -> String {
        snapshotBox.read()
    }

    /// Kick off resolution. Call once at app launch so the first real spawn
    /// doesn't pay the shell roundtrip.
    static func prewarm() {
        _ = task
    }

    private static let defaultPath = "/usr/bin:/bin:/usr/sbin:/sbin"
    private static let snapshotBox = SnapshotBox(
        value: ProcessInfo.processInfo.environment["PATH"] ?? defaultPath
    )

    private static let task: Task<String, Never> = Task.detached(priority: .userInitiated) {
        let resolved = await resolve()
        snapshotBox.write(resolved)
        return resolved
    }

    private static func resolve() async -> String {
        let fallback = snapshotBox.read()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // `-l` so profile/.zprofile runs (this is where homebrew/asdf prepend
        // PATH); `-c` rather than `-i` so we don't hang on prompts reading stdin.
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let gate = ResumeGate()

            process.terminationHandler = { proc in
                let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let stdout = String(data: data, encoding: .utf8) ?? ""
                // Some profiles (nvm/mise/direnv banners) write to stdout
                // before our `printf` runs. PATH entries can't contain `\n`,
                // so the path is always the trailing chunk after the last
                // newline.
                let tail = stdout
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .last
                    .map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if proc.terminationStatus == 0, !tail.isEmpty {
                    gate.resume(cont, with: tail)
                } else {
                    gate.resume(cont, with: fallback)
                }
            }

            do {
                try process.run()
            } catch {
                gate.resume(cont, with: fallback)
                return
            }

            // Hard cap so a slow profile (network calls, version-manager
            // bootstraps) can't stall every subprocess in the app. Matches
            // AgentLauncher.shellCommand's budget.
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) { [weak process] in
                guard let process, process.isRunning else { return }
                process.terminate()
                gate.resume(cont, with: fallback)
            }
        }
    }
}

private final class SnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(value: String) { self.value = value }

    func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func write(_ v: String) {
        lock.lock()
        defer { lock.unlock() }
        value = v
    }
}

/// One-shot resume guard. The continuation can be resumed from either the
/// terminationHandler or the timeout; whichever wins, the other becomes a
/// no-op.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(_ cont: CheckedContinuation<String, Never>, with value: String) {
        lock.lock()
        let alreadyResumed = resumed
        if !alreadyResumed { resumed = true }
        lock.unlock()
        guard !alreadyResumed else { return }
        cont.resume(returning: value)
    }
}
