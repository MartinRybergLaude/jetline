import Foundation
import Darwin

/// Owns a pseudo-terminal master file descriptor and the child process
/// running on the slave side. Drains output via `DispatchSourceRead`,
/// handles resize through `TIOCSWINSZ`, and harvests the exit code by
/// waiting for read EOF on the master before calling `waitpid`.
///
/// Why EOF-then-waitpid: SIGCHLD-driven termination loses the last ~100 ms
/// of output because the kernel only buffers what's already drained when
/// the read source flushes. EOF on the master is the kernel's signal that
/// every byte the child wrote has been delivered.
final class PTYProcess: @unchecked Sendable {
    /// Bytes received from the child's stdout/stderr (the master side).
    let outputHandler: (Data) -> Void
    /// Fires once after EOF + waitpid. The Int32 is the exit status from
    /// `waitpid`, decoded with `WIFEXITED` / `WEXITSTATUS`.
    let exitHandler: (Int32) -> Void

    private let executable: String
    private let args: [String]
    private let cwd: String
    private let env: [String: String]
    private let initialCols: UInt16
    private let initialRows: UInt16

    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var procSource: DispatchSourceProcess?
    private let queue = DispatchQueue(label: "PTYProcess.io", qos: .userInitiated)
    private var hasStarted = false
    private var hasReportedExit = false
    /// Reused across reads from the io queue so steady-state output
    /// doesn't allocate an 8 KB array per chunk.
    private var readBuffer = [UInt8](repeating: 0, count: 8192)

    init(
        executable: String,
        args: [String],
        cwd: String,
        env: [String: String],
        initialCols: UInt16 = 80,
        initialRows: UInt16 = 24,
        output: @escaping (Data) -> Void,
        exit: @escaping (Int32) -> Void
    ) {
        self.executable = executable
        self.args = args
        self.cwd = cwd
        self.env = env
        self.initialCols = initialCols
        self.initialRows = initialRows
        self.outputHandler = output
        self.exitHandler = exit
    }

    enum SpawnError: Error {
        case forkptyFailed(errno: Int32)
    }

    /// Fork, exec the configured executable on the slave, and start
    /// draining the master fd. Idempotent — second call is a no-op.
    func start() throws {
        if hasStarted { return }
        hasStarted = true

        var ws = winsize(
            ws_row: initialRows,
            ws_col: initialCols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // All argv/envp/path C strings are built in the parent before
        // forkpty. After fork, the child inherits a COW copy of memory but
        // only the calling thread — any other thread holding the malloc
        // lock at fork time leaves malloc effectively locked forever in
        // the child. The moment the child tries to allocate (Swift String
        // bridging, NSString, Array.map, strdup, lazy metadata init) it
        // deadlocks before reaching execve, the parent never sees PTY
        // output or EOF, and the new tab paints as libghostty's idle
        // cursor with no shell ever appearing. Async-signal-safety rules
        // (POSIX) say only a fixed list of C calls are allowed between
        // fork and exec — the child path below sticks to that list.
        let basename = (executable as NSString).lastPathComponent
        let argvSource = [basename] + args
        let envpSource = env.map { "\($0.key)=\($0.value)" }
        let argvCount = argvSource.count
        let envpCount = envpSource.count
        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: argvCount + 1
        )
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(
            capacity: envpCount + 1
        )
        for (i, s) in argvSource.enumerated() { argv[i] = strdup(s) }
        argv[argvCount] = nil
        for (i, s) in envpSource.enumerated() { envp[i] = strdup(s) }
        envp[envpCount] = nil
        let executableC = strdup(executable)
        let cwdC = strdup(cwd)

        defer {
            // Parent only — the child either replaces its image via
            // execve or exits via `_exit`, neither of which runs defers.
            for i in 0..<argvCount { free(argv[i]) }
            argv.deallocate()
            for i in 0..<envpCount { free(envp[i]) }
            envp.deallocate()
            free(executableC)
            free(cwdC)
        }

        var master: Int32 = -1
        let pid = withUnsafePointer(to: &ws) { wsPtr -> pid_t in
            forkpty(&master, nil, nil, UnsafeMutablePointer(mutating: wsPtr))
        }

        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

        if pid == 0 {
            // Child. Async-signal-safe C calls only — see comment above.
            // setpgid groups the child so SIGINT to -pid reaches every
            // descendant the agent spawns. argv[0] is the executable's
            // basename because Claude Code re-execs itself by argv[0].
            _ = setpgid(0, 0)
            _ = chdir(cwdC)
            _ = execve(executableC, argv, envp)
            _exit(127)
        }

        masterFd = master
        childPid = pid

        // Non-blocking master so partial reads don't stall the queue.
        let flags = fcntl(masterFd, F_GETFL, 0)
        _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

        startReadSource()
        startProcessWatch()
    }

    /// Write bytes to the child's stdin. Loops over EAGAIN/EINTR.
    /// FileHandle.write throws on EAGAIN and isn't an option here.
    func write(_ data: Data) {
        guard masterFd >= 0, !data.isEmpty else { return }
        let fd = masterFd
        queue.async {
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard var ptr = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let n = Darwin.write(fd, ptr, remaining)
                    if n > 0 {
                        ptr = ptr.advanced(by: n)
                        remaining -= n
                    } else if n < 0 {
                        let e = errno
                        if e == EINTR { continue }
                        if e == EAGAIN || e == EWOULDBLOCK {
                            // Spin briefly; backpressure on terminals is short-lived.
                            usleep(1000)
                            continue
                        }
                        return
                    } else {
                        return
                    }
                }
            }
        }
    }

    /// Update the slave's window size. Triggers SIGWINCH in the child.
    func resize(cols: UInt16, rows: UInt16, widthPx: UInt32, heightPx: UInt32) {
        guard masterFd >= 0 else { return }
        var ws = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: UInt16(min(Int(UInt16.max), Int(widthPx))),
            ws_ypixel: UInt16(min(Int(UInt16.max), Int(heightPx)))
        )
        _ = ioctl(masterFd, TIOCSWINSZ, &ws)
    }

    /// SIGINT to the entire process group. Group-targeted so any child
    /// that the agent spawned (subshell, code-running tool, etc.) also
    /// receives the interrupt. Writing 0x03 to the master only works
    /// when the slave is in cooked ISIG mode, which agents rarely are.
    func interrupt() {
        guard childPid > 0 else { return }
        _ = kill(-childPid, SIGINT)
    }

    /// SIGHUP the child's process group and the slave's foreground group so
    /// shells save history and agents clean up, mirroring a real terminal
    /// close, then SIGKILL whatever is still alive after `forceKillGrace`.
    /// The read source's cancel handler reaps the exit status and closes the
    /// master fd once the source is fully cancelled.
    ///
    /// Runs on the io queue so the `tcgetpgrp` read below is serialised
    /// against `reapChildIfNeeded` closing `masterFd` — reading a closed
    /// (and possibly recycled) descriptor could otherwise report another
    /// terminal's foreground group and kill an unrelated workspace's run.
    ///
    /// `completion` fires once every signalled group is gone, off the io
    /// queue. That is later than `exitHandler`, which reports the child's
    /// own exit: a shell hands back its status the moment it takes the
    /// SIGHUP, while the job it started can hold a port until the SIGKILL
    /// lands. Callers that need the port free — an exclusive run replacing
    /// a peer — have to wait for this, not for the exit.
    func terminate(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            let groups = self.signalTargets()
            for group in groups {
                _ = kill(-group, SIGHUP)
            }
            Self.settleTermination(
                of: groups,
                on: self.queue,
                forceKillAfter: .now() + Self.forceKillGrace,
                completion: completion
            )
            self.procSource?.cancel()
            self.procSource = nil
            self.readSource?.cancel()
            self.readSource = nil
        }
    }

    /// Every process group worth signalling: the child's own, plus the
    /// slave's foreground group when they differ.
    ///
    /// They differ whenever the child turns on job control — `zsh -i` on a
    /// tty does, which is how repository scripts run — because each job then
    /// gets a process group of its own. Signalling `-childPid` alone reaches
    /// the shell and nothing it started, so a `npm run dev` outlived Stop
    /// and kept its port. `tcgetpgrp` on the master reports the slave's
    /// foreground group on Darwin even though we are outside its session,
    /// which is the same group the kernel would signal for a ⌃C typed into
    /// a real terminal.
    private func signalTargets() -> [pid_t] {
        guard childPid > 0 else { return [] }
        var groups = [childPid]
        if masterFd >= 0 {
            let foreground = tcgetpgrp(masterFd)
            if foreground > 0, foreground != childPid {
                groups.append(foreground)
            }
        }
        return groups
    }

    /// Grace between the SIGHUP and the SIGKILL that backs it up. Long
    /// enough for a dev server to close its listener, short enough that the
    /// port is free before the user retries.
    private static let forceKillGrace: DispatchTimeInterval = .seconds(2)

    /// How often the poll below re-checks whether the signalled groups have
    /// gone away.
    private static let terminationPollInterval: DispatchTimeInterval = .milliseconds(50)

    /// Poll the signalled groups until they are gone, SIGKILLing whatever
    /// outlives `forceKillAfter`, then report back.
    ///
    /// The escalation is unconditional by design: SIGHUP is advisory, and a
    /// script that traps or ignores it keeps running — and keeps holding its
    /// port — while the shell that spawned it exits on cue, so gating the
    /// escalation on the child's own exit (as `reapChildIfNeeded` does for a
    /// wedged child) never fires for the case that actually leaks. Polling
    /// rather than sleeping out the full grace means the common case, where
    /// the SIGHUP is honoured, settles in a poll interval instead of seconds.
    ///
    /// Takes plain pids rather than `self` so a `PTYProcess` released
    /// mid-teardown doesn't cancel the escalation. The `kill(_:0)` probe
    /// skips groups that are already gone; a pid recycled into a new group
    /// leader inside the grace window would be signalled in their place,
    /// which is the same exposure the unconditional SIGKILL here had before
    /// it became a SIGHUP.
    private static func settleTermination(
        of groups: [pid_t],
        on queue: DispatchQueue,
        forceKillAfter deadline: DispatchTime,
        forceKilled: Bool = false,
        completion: (@Sendable () -> Void)?
    ) {
        let remaining = groups.filter { kill(-$0, 0) == 0 }
        guard !remaining.isEmpty else {
            completion?()
            return
        }
        // SIGKILL can't be caught, so a group that survives it is down to
        // zombies awaiting a parent we don't own. Nothing left to wait for.
        guard !forceKilled else {
            completion?()
            return
        }

        let escalating = DispatchTime.now() >= deadline
        if escalating {
            for group in remaining {
                _ = kill(-group, SIGKILL)
            }
        }
        queue.asyncAfter(deadline: .now() + terminationPollInterval) {
            settleTermination(
                of: remaining,
                on: queue,
                forceKillAfter: deadline,
                forceKilled: escalating,
                completion: completion
            )
        }
    }

    private func startReadSource() {
        let fd = masterFd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainOutput()
        }
        source.setCancelHandler { [weak self] in
            self?.reapChildIfNeeded()
        }
        readSource = source
        source.resume()
    }

    private func startProcessWatch() {
        guard childPid > 0 else { return }
        let source = DispatchSource.makeProcessSource(
            identifier: childPid,
            eventMask: .exit,
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.procSource?.cancel()
            self.procSource = nil
            self.drainOutput()
            self.readSource?.cancel()
        }
        procSource = source
        source.resume()
    }

    /// Read until EAGAIN. EOF (read returns 0) means the child has
    /// closed all writers — we cancel the source, which fires
    /// `reapChildIfNeeded` to harvest the exit status.
    private func drainOutput() {
        let fd = masterFd
        guard fd >= 0 else { return }

        while true {
            let n = readBuffer.withUnsafeMutableBufferPointer { bp -> Int in
                read(fd, bp.baseAddress, bp.count)
            }
            if n > 0 {
                let chunk = readBuffer.withUnsafeBufferPointer { bp in
                    Data(bytes: bp.baseAddress!, count: n)
                }
                outputHandler(chunk)
            } else if n == 0 {
                // EOF — child closed the slave. Reap and notify.
                readSource?.cancel()
                return
            } else {
                let e = errno
                if e == EINTR { continue }
                if e == EAGAIN || e == EWOULDBLOCK {
                    return
                }
                // Hard read error (e.g. EIO when slave is gone). Treat as EOF.
                readSource?.cancel()
                return
            }
        }
    }

    private func reapChildIfNeeded() {
        if hasReportedExit { return }
        hasReportedExit = true

        procSource?.cancel()
        procSource = nil

        var status: Int32 = 0
        let pid = childPid
        guard pid > 0 else {
            exitHandler(0)
            return
        }

        // Poll with WNOHANG so a child that hasn't fully exited (rare —
        // master EOF usually means the kernel already collected it) can't
        // wedge the io queue. After ~1s we SIGKILL its groups and wait one
        // more pass; after ~2s we give up and report exit anyway.
        let deadline = DispatchTime.now() + .seconds(2)
        var waited: pid_t = 0
        var killed = false
        while DispatchTime.now() < deadline {
            waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0 {
                // ECHILD (already reaped) or other error — nothing to do.
                break
            }
            if !killed && DispatchTime.now() > deadline - .seconds(1) {
                for group in signalTargets() {
                    _ = kill(-group, SIGKILL)
                }
                killed = true
            }
            usleep(20_000)
        }

        let exitCode: Int32
        if waited == pid && (status & 0x7f) == 0 {
            exitCode = (status >> 8) & 0xff
        } else if waited == pid && (status & 0x7f) != 0 {
            // Killed by signal — surface 128 + signal so callers can tell.
            exitCode = 128 + (status & 0x7f)
        } else {
            exitCode = 0
        }

        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
        }

        exitHandler(exitCode)
    }

    var pid: pid_t { childPid }
}
