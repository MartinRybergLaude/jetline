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
    /// top. Used everywhere we spawn — keeps inherited PATH/HOME/etc.
    static func inheritedEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in overrides { merged[k] = v }
        return merged
    }

    static func run(
        executable: String,
        args: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        closeStdin: Bool = false,
        timeout: TimeInterval? = nil
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            runSync(
                executable: executable,
                args: args,
                cwd: cwd,
                env: env,
                closeStdin: closeStdin,
                timeout: timeout
            )
        }.value
    }

    private static func runSync(
        executable: String,
        args: [String],
        cwd: String?,
        env: [String: String],
        closeStdin: Bool,
        timeout: TimeInterval?
    ) -> Result {
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
        // run on its private kqueue source instead of pinning a Task thread
        // inside `readDataToEndOfFile`. Two reasons we can't just bound the
        // synchronous read by closing the fd from another thread:
        //
        // 1. `close()` on a `FileHandle` while a parallel `read()` syscall
        //    is in flight raises an ObjC `NSFileHandleOperationException`
        //    that Swift can't catch with `try?` — it crashes the app.
        // 2. On macOS, closing a pipe fd from another thread doesn't even
        //    unblock the read; the kernel keeps the read alive against the
        //    file table entry. So the close would crash without helping.
        //
        // With `readabilityHandler`, "stop draining" is just clearing the
        // handler — no blocking syscall to interrupt.
        let outReader = PipeDrain(handle: outPipe.fileHandleForReading)
        let errReader = PipeDrain(handle: errPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            outReader.cancel()
            errReader.cancel()
            return Result(stdout: "", stderr: "spawn failed: \(error)", status: -1)
        }

        if let timeout {
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            process.waitUntilExit()
            killer.cancel()
        } else {
            process.waitUntilExit()
        }

        // Bounded drain. The process is dead, so anything still buffered in
        // the pipe will arrive in microseconds. If reads are still pending
        // after the grace period, a forked-and-detached descendant
        // (git's `fsmonitor--daemon`, SSH `ControlMaster`, credential
        // helpers, shell-init agents) inherited fd 1/2 and is keeping the
        // write ends open. EOF will never come; we don't want its output
        // anyway. Cancel the drainers and move on.
        let stdoutData = outReader.waitAndCollect(timeout: .milliseconds(250))
        let stderrData = errReader.waitAndCollect(timeout: .milliseconds(250))

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
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
