import Foundation

/// Shared `Process` plumbing. Captures stdout+stderr, merges env on top of
/// the inherited environment, optionally enforces a timeout. Always returns
/// — spawn failures are reported as `status = -1` with the OS error in
/// stderr so callers can pattern-match without try/catch noise.
enum Subprocess {
    struct Result: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
        var success: Bool { status == 0 }
    }

    /// Returns the current process environment with `overrides` layered on
    /// top. PATH is replaced with the login-shell PATH (`LoginShellPath`)
    /// unless the caller supplies their own — without this, Launchpad-
    /// launched apps inherit the minimal launchd PATH and can't see homebrew
    /// binaries. Snapshot is best-effort; `Subprocess.run` awaits resolution
    /// for correctness, but sync callers (e.g. `GhosttyEmulator.spawn`) get
    /// whichever value has been resolved so far.
    static func inheritedEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        if overrides["PATH"] == nil {
            merged["PATH"] = LoginShellPath.snapshot()
        }
        for (k, v) in overrides { merged[k] = v }
        return merged
    }

    /// Spawn `executable`, capture output, return once the child exits.
    /// Truly async: no caller thread is held for the child's lifetime.
    ///
    /// Implementation note — the previous shape was `Task.detached { runSync(...) }`
    /// with `process.waitUntilExit()` inside, which blocked a cooperative
    /// pool thread per concurrent subprocess. With many parallel git/gh
    /// calls (`PRTracker.pollLocal` fans out N workspaces × ~3 git subprocs)
    /// the pool's bounded thread count became a real ceiling. Replacing the
    /// blocking wait with `terminationHandler` + checked continuation drops
    /// the thread-per-subprocess footprint to zero while the child runs;
    /// the post-exit drain grace is the only place we still consume a
    /// global-queue thread, and that's bounded by `250 ms`.
    static func run(
        executable: String,
        args: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        closeStdin: Bool = false,
        timeout: TimeInterval? = nil
    ) async -> Result {
        // Await login-shell PATH resolution before composing env. The snapshot
        // read inside `inheritedEnvironment` is then guaranteed to see the
        // resolved value (the resolver writes the snapshot before the task
        // completes), so non-interactive spawns like `gh`/`git` find homebrew
        // binaries even under a Launchpad launch.
        _ = await LoginShellPath.get()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = Subprocess.inheritedEnvironment(overrides: env)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if closeStdin { process.standardInput = FileHandle.nullDevice }

        // Drain stdout/stderr via Foundation's `readabilityHandler` so reads
        // run on its private kqueue source instead of pinning a thread inside
        // a blocking `readDataToEndOfFile`. See PipeDrain for why we don't
        // close the fd from another thread (ObjC exception inside read).
        let outDrain = PipeDrain(handle: outPipe.fileHandleForReading)
        let errDrain = PipeDrain(handle: errPipe.fileHandleForReading)

        return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            // Fires once the child has exited and Process has observed it.
            // Hop off Process's notification queue before doing the bounded
            // drain wait — PipeDrain.waitAndCollect blocks on a semaphore,
            // and we don't want to wedge whichever internal queue Process
            // uses for terminationHandler callbacks.
            process.terminationHandler = { proc in
                DispatchQueue.global(qos: .userInitiated).async {
                    let stdoutData = outDrain.waitAndCollect(timeout: .milliseconds(250))
                    let stderrData = errDrain.waitAndCollect(timeout: .milliseconds(250))
                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                    cont.resume(returning: Result(
                        stdout: stdout,
                        stderr: stderr,
                        status: proc.terminationStatus
                    ))
                }
            }

            do {
                try process.run()
            } catch {
                // `process.run()` threw — terminationHandler will never
                // fire because the child never started. Tear the drains
                // down and resume with the spawn-failure sentinel.
                outDrain.cancel()
                errDrain.cancel()
                cont.resume(returning: Result(
                    stdout: "",
                    stderr: "spawn failed: \(error)",
                    status: -1
                ))
                return
            }

            if let timeout {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak process] in
                    if process?.isRunning == true { process?.terminate() }
                }
            }
        }
    }
}

/// Pulls bytes off a child-process pipe via `readabilityHandler`.
/// The drain runs on Foundation's private dispatch source, not on the
/// caller's thread, so the caller can abandon the drain at any time
/// (`cancel`) by clearing the handler — no in-flight syscall to
/// interrupt, and no need to close the fd from a parallel thread,
/// which raises an uncatchable ObjC exception inside the read.
private final class PipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var done = false
    private let semaphore = DispatchSemaphore(value: 0)

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let chunk = handle.availableData
            if chunk.isEmpty {
                self.markDone()
            } else {
                self.lock.lock()
                self.data.append(chunk)
                self.lock.unlock()
            }
        }
    }

    /// Wait for EOF up to `timeout`, then return whatever has been
    /// collected so far. After return, the handler is detached and no
    /// further bytes are appended.
    func waitAndCollect(timeout: DispatchTimeInterval) -> Data {
        _ = semaphore.wait(timeout: .now() + timeout)
        cancel()
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func cancel() {
        markDone()
    }

    private func markDone() {
        let wasFirst: Bool
        lock.lock()
        wasFirst = !done
        done = true
        lock.unlock()
        if wasFirst {
            handle.readabilityHandler = nil
            semaphore.signal()
        }
    }
}
