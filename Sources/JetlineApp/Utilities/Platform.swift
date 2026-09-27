import Foundation
import CJetlineSys
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// The few places where the engine's process plumbing differs between macOS
/// and Linux.
enum Platform {
    /// The user's login shell: `$SHELL`, else the passwd entry, else the
    /// platform's usual default. A daemon started from systemd or a bare
    /// `ssh host cmd` may not have `$SHELL` set.
    static let defaultShell: String = {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if !shell.isEmpty, FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        #if os(macOS)
        return "/bin/zsh"
        #else
        return FileManager.default.isExecutableFile(atPath: "/bin/bash") ? "/bin/bash" : "/bin/sh"
        #endif
    }()

    static var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static var hostName: String {
        ProcessInfo.processInfo.hostName
    }

    static var name: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "unknown"
        #endif
    }
}

/// `write(2)` that loops over short writes and EINTR. Returns the errno that
/// stopped it, or nil once every byte is out. `EAGAIN` on a non-blocking fd
/// waits for it to drain (`poll`) rather than spinning.
func writeAll(fd: Int32, _ base: UnsafeRawPointer, count: Int) -> Int32? {
    var offset = 0
    while offset < count {
        #if canImport(Darwin)
        let n = Darwin.write(fd, base + offset, count - offset)
        #elseif canImport(Glibc)
        let n = Glibc.write(fd, base + offset, count - offset)
        #else
        let n = Musl.write(fd, base + offset, count - offset)
        #endif
        if n > 0 {
            offset += n
        } else if n < 0 {
            let e = errno
            if e == EINTR { continue }
            if e == EAGAIN || e == EWOULDBLOCK {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 1000)
                continue
            }
            return e
        } else {
            return EIO
        }
    }
    return nil
}

func writeAll(fd: Int32, _ data: Data) -> Int32? {
    data.withUnsafeBytes { raw -> Int32? in
        guard let base = raw.baseAddress else { return nil }
        return writeAll(fd: fd, base, count: raw.count)
    }
}

/// Fires `handler` on `queue` once `pid` exits, without reaping it — the
/// owner still collects the status with `waitpid`. kqueue on Darwin
/// (`DispatchSource.makeProcessSource`); a pidfd read source on Linux, since
/// corelibs-libdispatch has no process sources. Where pidfds are missing
/// (kernels before 5.3) it polls with `waitid(WNOWAIT)`, which peeks at the
/// exit without consuming it.
final class ProcessExitSource: @unchecked Sendable {
    private var source: DispatchSourceProtocol?

    init(pid: pid_t, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        #if canImport(Darwin)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: handler)
        self.source = source
        source.resume()
        #else
        let fd = jl_pidfd_open(pid)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in
                // Level-triggered: fire once, then stand down.
                self?.cancel()
                handler()
            }
            source.setCancelHandler { close(fd) }
            self.source = source
            source.resume()
        } else {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
            timer.setEventHandler { [weak self] in
                var info = siginfo_t()
                let r = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
                // A zero pid in the siginfo means "still running".
                if r != 0 || info._sifields._kill.si_pid != 0 {
                    self?.cancel()
                    handler()
                }
            }
            self.source = timer
            timer.resume()
        }
        #endif
    }

    func cancel() {
        source?.cancel()
        source = nil
    }
}
