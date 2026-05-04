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

        var master: Int32 = -1
        let pid = withUnsafePointer(to: &ws) { wsPtr -> pid_t in
            forkpty(&master, nil, nil, UnsafeMutablePointer(mutating: wsPtr))
        }

        if pid < 0 {
            throw SpawnError.forkptyFailed(errno: errno)
        }

        if pid == 0 {
            // Child. Set up the process group so SIGINT to -pid reaches every
            // descendant Claude Code spawns. Then chdir, build argv/envp, and
            // execve. argv[0] must be the executable's basename — Claude Code
            // reads it for its own re-exec path.
            _ = setpgid(0, 0)
            _ = chdir(cwd)

            let basename = (executable as NSString).lastPathComponent
            var argvStrings: [UnsafeMutablePointer<CChar>?] = ([basename] + args).map { strdup($0) }
            argvStrings.append(nil)

            var envpStrings: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
            envpStrings.append(nil)

            argvStrings.withUnsafeBufferPointer { argvBP in
                envpStrings.withUnsafeBufferPointer { envpBP in
                    _ = execve(executable, argvBP.baseAddress, envpBP.baseAddress)
                }
            }
            // execve only returns on failure.
            _exit(127)
        }

        masterFd = master
        childPid = pid

        // Non-blocking master so partial reads don't stall the queue.
        let flags = fcntl(masterFd, F_GETFL, 0)
        _ = fcntl(masterFd, F_SETFL, flags | O_NONBLOCK)

        startReadSource()
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

    /// Force-kill the child group, then close the master fd. The read
    /// source's cancel handler reaps the exit status.
    func terminate() {
        if childPid > 0 {
            _ = kill(-childPid, SIGKILL)
        }
        readSource?.cancel()
        readSource = nil
        if masterFd >= 0 {
            close(masterFd)
            masterFd = -1
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

        var status: Int32 = 0
        let pid = childPid
        guard pid > 0 else {
            exitHandler(0)
            return
        }

        // Poll with WNOHANG so a child that hasn't fully exited (rare —
        // master EOF usually means the kernel already collected it) can't
        // wedge the io queue. After ~1s we SIGKILL the group and wait one
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
                _ = kill(-pid, SIGKILL)
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
