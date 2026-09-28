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

    private static let processSlots = ConcurrencyGate(limit: 12)

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
        await processSlots.acquire()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = Subprocess.inheritedEnvironment(overrides: env)

        guard let outDrain = PipeDrain() else { return spawnFailure(errno) }
        guard let errDrain = PipeDrain() else {
            let error = errno
            outDrain.cancel()
            outDrain.closeWriteEnd()
            return spawnFailure(error)
        }
        process.standardOutput = outDrain.writeEnd
        process.standardError = errDrain.writeEnd
        if closeStdin { process.standardInput = FileHandle.nullDevice }

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
                    processSlots.release()
                    cont.resume(returning: Result(
                        stdout: stdout,
                        stderr: stderr,
                        status: proc.terminationStatus
                    ))
                }
            }

            do {
                try process.run()
                // The child has its copies; EOF only comes once ours are gone.
                outDrain.closeWriteEnd()
                errDrain.closeWriteEnd()
            } catch {
                // `process.run()` threw — terminationHandler will never
                // fire because the child never started. Tear the drains
                // down and resume with the spawn-failure sentinel.
                outDrain.cancel()
                errDrain.cancel()
                outDrain.closeWriteEnd()
                errDrain.closeWriteEnd()
                processSlots.release()
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

    /// Out of file descriptors, most likely: report it like a failed spawn.
    private static func spawnFailure(_ error: Int32) -> Result {
        let reason = String(cString: strerror(error))
        processSlots.release()
        return Result(stdout: "", stderr: "spawn failed: couldn't create a pipe (\(reason))", status: -1)
    }
}

private final class ConcurrencyGate: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if inUse < limit {
                inUse += 1
                lock.unlock()
                cont.resume()
            } else {
                waiters.append(cont)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiters.isEmpty {
            inUse -= 1
            lock.unlock()
        } else {
            let next = waiters.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/// A child-process output pipe and the drain on its read end. The read
/// end is a raw fd on a dispatch source, closed by the source's cancel
/// handler: the caller can abandon the drain at any time (`cancel`) with
/// no read in flight to interrupt, and the fd is always closed.
/// `Pipe` + `readabilityHandler` isn't used because corelibs Foundation
/// never closes a read handle that had a handler, leaking two fds per
/// subprocess until the daemon runs out; its `Pipe()` then hands back
/// fd -1, and setting a handler on that traps.
private final class PipeDrain: @unchecked Sendable {
    /// The end the child writes to. `closeWriteEnd()` once it has spawned.
    let writeEnd: FileHandle
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var data = Data()
    private var done = false
    private let semaphore = DispatchSemaphore(value: 0)

    init?() {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0]
        // Close-on-exec so other children don't inherit these; the child's
        // own stdout/stderr come from dup2, which clears the flag.
        _ = fcntl(readFD, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
        writeEnd = FileHandle(fileDescriptor: fds[1], closeOnDealloc: false)
        source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: DispatchQueue(label: "jetline.subprocess.drain"))
        source.setEventHandler { [weak self] in self?.drain(readFD) }
        source.setCancelHandler { _ = close(readFD) }
        source.resume()
    }

    func closeWriteEnd() {
        try? writeEnd.close()
    }

    private func drain(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                lock.lock()
                data.append(contentsOf: buffer[0..<n])
                lock.unlock()
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                markDone()
                return
            }
        }
    }

    /// Wait for EOF up to `timeout`, then return whatever has been
    /// collected so far. After return, no further bytes are appended.
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
            source.cancel()
            semaphore.signal()
        }
    }
}
