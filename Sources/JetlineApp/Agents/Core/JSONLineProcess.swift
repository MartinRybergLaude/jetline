import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A child process spoken to in newline-delimited JSON over stdin/stdout —
/// the framing both `claude --input-format stream-json` and
/// `codex app-server` use.
///
/// Spawned with `posix_spawn` rather than `Foundation.Process` so the child
/// leads its own session (and so its own process group): agents run
/// shells, test runners and dev servers, and signalling the group on stop
/// is the only way those don't outlive the chat. A new session also means
/// no controlling terminal — when Jetline itself runs under one (`make
/// run`, tests), a child left in a background process group of that tty
/// gets SIGTTOU-stopped the moment one of its hooks touches the terminal.
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` keeps the app's other descriptors (PTY
/// masters, the SQLite file) out of the child.
final class JSONLineProcess: @unchecked Sendable {
    struct Launch: Sendable {
        var executable: String
        var args: [String]
        var cwd: String
        var env: [String: String]
    }

    /// stdout, one element per line, newline stripped. Finishes at EOF.
    let lines: AsyncStream<Data>
    private let linesContinuation: AsyncStream<Data>.Continuation

    private let launch: Launch
    private let queue = DispatchQueue(label: "jetline.agent.process")
    /// Separate from `queue` so a child that stops reading stdin (and so
    /// blocks our write) can't stall stdout draining — which would deadlock
    /// the pair of us.
    private let writeQueue = DispatchQueue(label: "jetline.agent.process.stdin")

    private var pid: pid_t = 0
    private var stdinFd: Int32 = -1
    private var stdoutFd: Int32 = -1
    private var stderrFd: Int32 = -1
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var processSource: ProcessExitSource?

    private var lineBuffer = Data()
    private var stderrBuffer = Data()
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitStatus: Int32?
    private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
    private let lock = NSLock()

    /// Lines longer than this are dropped rather than buffered without
    /// bound — a runaway tool result shouldn't take the app's memory with
    /// it. Generous because Claude's init message and large file reads
    /// legitimately run to megabytes.
    static let maxLineLength = 64 * 1024 * 1024
    private static let stderrTailLength = 16 * 1024

    /// Protocol trace: when `JETLINE_AGENT_TRACE` names a file, every line
    /// in both directions is appended to it. For debugging CLI protocol
    /// changes; off by default.
    private let trace: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["JETLINE_AGENT_TRACE"], !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
        return handle
    }()
    private let traceLock = NSLock()

    private func traceLine(_ direction: String, _ data: Data) {
        guard let trace else { return }
        traceLock.withLock {
            trace.write(Data("\(direction) ".utf8) + data + Data([0x0A]))
        }
    }

    init(_ launch: Launch) {
        self.launch = launch
        (lines, linesContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    deinit {
        if stdinFd >= 0 { close(stdinFd) }
    }

    var processIdentifier: pid_t { lock.withLock { pid } }

    /// Last few KB of stderr — what the CLI printed before dying.
    var stderrTail: String {
        lock.withLock { String(decoding: stderrBuffer, as: UTF8.self) }
    }

    // MARK: Spawn

    func start() throws {
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard Self.makePipe(&stdinPipe), Self.makePipe(&stdoutPipe), Self.makePipe(&stderrPipe) else {
            throw AgentError.launchFailed(String(cString: strerror(errno)))
        }

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&fileActions, launch.cwd)

        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        #if canImport(Darwin)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        #else
        // glibc has no CLOEXEC_DEFAULT: close everything above stderr in the
        // child instead (the dup2s above run first). POSIX_SPAWN_SETSID is
        // 0x80 in glibc but only visible under _GNU_SOURCE.
        posix_spawn_file_actions_addclosefrom_np(&fileActions, 3)
        posix_spawnattr_setflags(
            &attributes,
            Int16(0x80 | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        )
        #endif
        // The child inherits the spawning thread's signal mask, and GCD
        // worker threads block SIGCHLD. Codex's async runtime reaps its
        // hook and tool processes on SIGCHLD, so with it blocked every
        // child looks immortal and the turn hangs. Start with nothing
        // blocked.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        // Reset every signal to its default in the child: the app ignores
        // SIGPIPE, and an inherited ignore would change how the agent's own
        // pipelines (`cmd | head`) terminate.
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = [launch.executable] + launch.args
        let envp = launch.env.map { "\($0.key)=\($0.value)" }
        var childPid: pid_t = 0
        let result = withCStrings(argv) { argvPtr in
            withCStrings(envp) { envpPtr in
                posix_spawn(&childPid, launch.executable, &fileActions, &attributes, argvPtr, envpPtr)
            }
        }

        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard result == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw AgentError.launchFailed(String(cString: strerror(result)))
        }

        // A write after the child exits must fail with EPIPE, not deliver
        // SIGPIPE to the whole app.
        #if canImport(Darwin)
        _ = fcntl(stdinPipe[1], F_SETNOSIGPIPE, 1)
        #endif
        // (Linux has no per-fd equivalent; the daemon ignores SIGPIPE.)
        _ = fcntl(stdinPipe[1], F_SETFD, FD_CLOEXEC)
        for fd in [stdoutPipe[0], stderrPipe[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        lock.withLock {
            pid = childPid
            stdinFd = stdinPipe[1]
            stdoutFd = stdoutPipe[0]
            stderrFd = stderrPipe[0]
        }
        queue.sync {
            startStdoutSource()
            startStderrSource()
            startProcessSource()
        }
    }

    // MARK: stdin

    /// Write one JSON line. Returns once the bytes are in the pipe; throws
    /// if the child has gone away.
    func send(_ value: JSONValue) async throws {
        var data = value.serialized()
        data.append(0x0A)
        try await write(data)
    }

    func write(_ data: Data) async throws {
        traceLine(">>", data.last == 0x0A ? data.dropLast() : data)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writeQueue.async { [self] in
                let fd = lock.withLock { stdinFd }
                guard fd >= 0 else {
                    cont.resume(throwing: AgentError.notRunning)
                    return
                }
                let failure = writeAll(fd: fd, data)
                if failure != nil {
                    cont.resume(throwing: AgentError.notRunning)
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// Close stdin — the conventional "no more input" for both CLIs.
    func closeStdin() {
        writeQueue.async { [self] in
            lock.withLock {
                if stdinFd >= 0 {
                    close(stdinFd)
                    stdinFd = -1
                }
            }
        }
    }

    // MARK: Termination

    /// SIGTERM the process group, then SIGKILL whatever is left after
    /// `grace`. Returns the exit status once the child is reaped.
    @discardableResult
    func terminate(grace: Duration = .seconds(2)) async -> Int32 {
        let group = processIdentifier
        guard group > 0 else { return -1 }
        closeStdin()
        _ = kill(-group, SIGTERM)
        let status = await withTaskGroup(of: Int32?.self) { tasks in
            tasks.addTask { await self.waitForExit() }
            tasks.addTask {
                try? await Task.sleep(for: grace)
                return nil
            }
            let first = await tasks.next() ?? nil
            if let first {
                tasks.cancelAll()
                return first
            }
            _ = kill(-group, SIGKILL)
            return await self.waitForExit()
        }
        // The CLI exiting doesn't mean its children did: a backgrounded
        // `npm run dev` keeps the group alive. Sweep it.
        if kill(-group, 0) == 0 {
            _ = kill(-group, SIGKILL)
        }
        return status
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { cont in
            lock.lock()
            if let status = exitStatus {
                lock.unlock()
                cont.resume(returning: status)
            } else {
                exitWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    // MARK: Reading

    private func startStdoutSource() {
        let fd = stdoutFd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainStdout() }
        source.setCancelHandler { close(fd) }
        stdoutSource = source
        source.resume()
    }

    private func startStderrSource() {
        let fd = stderrFd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drainStderr() }
        source.setCancelHandler { close(fd) }
        stderrSource = source
        source.resume()
    }

    private func startProcessSource() {
        processSource = ProcessExitSource(pid: pid, queue: queue) { [weak self] in self?.reap() }
    }

    private func drainStdout() {
        // The cancel handler closes the fd; reading it after that could hit
        // a recycled descriptor.
        guard !stdoutClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(stdoutFd, &buffer, buffer.count)
            if n > 0 {
                appendStdout(buffer[0..<n])
            } else if n == 0 {
                finishStdout()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                finishStdout()
                return
            }
        }
    }

    private func appendStdout(_ bytes: ArraySlice<UInt8>) {
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            lineBuffer.append(contentsOf: bytes[start..<newline])
            emitLine()
            start = newline + 1
        }
        lineBuffer.append(contentsOf: bytes[start...])
        if lineBuffer.count > Self.maxLineLength {
            // Drop the oversized line. The remainder up to its newline is
            // discarded as garbage by the JSON parse downstream.
            lineBuffer.removeAll(keepingCapacity: false)
        }
    }

    private func emitLine() {
        defer { lineBuffer.removeAll(keepingCapacity: true) }
        var line = lineBuffer
        if line.last == 0x0D { line.removeLast() }
        guard !line.isEmpty else { return }
        traceLine("<<", line)
        linesContinuation.yield(line)
    }

    private func finishStdout() {
        guard !stdoutClosed else { return }
        stdoutClosed = true
        if !lineBuffer.isEmpty { emitLine() }
        stdoutSource?.cancel()
        stdoutSource = nil
        linesContinuation.finish()
    }

    private func drainStderr() {
        guard !stderrClosed else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(stderrFd, &buffer, buffer.count)
            if n > 0 {
                lock.withLock {
                    stderrBuffer.append(contentsOf: buffer[0..<n])
                    if stderrBuffer.count > Self.stderrTailLength {
                        stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrTailLength)
                    }
                }
            } else if n < 0, errno == EINTR {
                continue
            } else {
                if n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    stderrClosed = true
                    stderrSource?.cancel()
                    stderrSource = nil
                }
                return
            }
        }
    }

    private func reap() {
        processSource?.cancel()
        processSource = nil
        var status: Int32 = 0
        var waited: pid_t
        repeat {
            waited = waitpid(pid, &status, 0)
        } while waited < 0 && errno == EINTR
        let code: Int32
        if waited == pid {
            if (status & 0x7f) == 0 {
                code = (status >> 8) & 0xff
            } else {
                code = 128 + (status & 0x7f)
            }
        } else {
            code = -1
        }
        // Flush whatever the child wrote before exiting, then close stdout
        // even if a grandchild still holds the write end open — otherwise
        // `lines` would never finish.
        drainStdout()
        finishStdout()
        drainStderr()
        // On the write queue, after any write in progress: closing the fd
        // under a running `write` loop could hand its remaining bytes to
        // whatever reuses the descriptor number.
        closeStdin()
        let waiters: [CheckedContinuation<Int32, Never>] = lock.withLock {
            exitStatus = code
            defer { exitWaiters.removeAll() }
            return exitWaiters
        }
        for waiter in waiters { waiter.resume(returning: code) }
    }
}

/// Build a NULL-terminated `char *[]` for the duration of `body`.
extension JSONLineProcess {
    /// A pipe whose ends don't leak into unrelated children. The spawn's
    /// dup2 onto 0/1/2 clears the flag on the child's copies.
    fileprivate static func makePipe(_ fds: inout [Int32]) -> Bool {
        guard pipe(&fds) == 0 else { return false }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return true
    }
}

private func withCStrings<R>(
    _ strings: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
) -> R {
    let pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}
