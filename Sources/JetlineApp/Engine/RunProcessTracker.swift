import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Remembers every process a run script starts, so Stop can reach the ones
/// that left its process groups: `nohup … &`, `setsid`, a child started in
/// a new session. Signalling the PTY's groups misses those, and they keep
/// the run's ports.
///
/// Descendants are found by walking parent pids, polled while the run
/// lives: once a detached process's parent exits it is reparented to init
/// and the link is gone, so it has to have been seen before that.
/// (Environment tagging would survive reparenting, but macOS no longer lets
/// a process read another's environment.) A daemon that double-forks
/// between polls escapes; the repository's stop script covers those.
final class RunProcessTracker: @unchecked Sendable {
    /// A pid plus its start time, so a recycled pid isn't mistaken for the
    /// process we saw.
    struct Process: Hashable, Sendable {
        var pid: pid_t
        var start: UInt64
    }

    private let queue = DispatchQueue(label: "jetline.run-tracker", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var root: Process?
    private var known: Set<Process> = []

    private static let pollInterval: DispatchTimeInterval = .seconds(1)

    /// Start following `pid` (the run's shell) and everything below it.
    func track(root pid: pid_t) {
        queue.async { [self] in
            let table = Self.processTable()
            guard let start = table[pid]?.start else { return }
            root = Process(pid: pid, start: start)
            scan(table)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.scan(Self.processTable()) }
            self.timer?.cancel()
            self.timer = timer
            timer.resume()
        }
    }

    /// Record what is running now. Call right before signalling the run, so
    /// a process started since the last poll isn't missed.
    func refresh() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                scan(Self.processTable())
                continuation.resume()
            }
        }
    }

    /// SIGTERM every remembered process still alive, SIGKILL what outlives
    /// `grace`, and stop tracking. Returns once they are gone.
    func terminateAll(grace: Duration = .seconds(3)) async {
        let targets: [Process] = await withCheckedContinuation { continuation in
            queue.async { [self] in
                timer?.cancel()
                timer = nil
                let table = Self.processTable()
                scan(table)
                let alive = known.filter { table[$0.pid]?.start == $0.start }
                known = []
                root = nil
                continuation.resume(returning: Array(alive))
            }
        }
        guard !targets.isEmpty else { return }
        for process in targets { _ = kill(process.pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        var alive = targets
        while !alive.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            let table = Self.processTable()
            alive = alive.filter { table[$0.pid]?.start == $0.start }
        }
        for process in alive { _ = kill(process.pid, SIGKILL) }
    }

    /// Add every descendant of the root, or of a process already known, to
    /// `known`; forget known processes that have exited. On `queue`.
    private func scan(_ table: [pid_t: (ppid: pid_t, start: UInt64)]) {
        known = known.filter { table[$0.pid]?.start == $0.start }
        var parents = Set(known.map(\.pid))
        if let root, table[root.pid]?.start == root.start { parents.insert(root.pid) }
        guard !parents.isEmpty else { return }
        var children: [pid_t: [pid_t]] = [:]
        for (pid, entry) in table { children[entry.ppid, default: []].append(pid) }
        var pending = Array(parents)
        let me = getpid()
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where child != me {
                guard let start = table[child]?.start else { continue }
                if known.insert(Process(pid: child, start: start)).inserted {
                    pending.append(child)
                }
            }
        }
    }

    // MARK: - Process table

    #if canImport(Darwin)
    /// Every process's parent and start time (`KERN_PROC_ALL`).
    static func processTable() -> [pid_t: (ppid: pid_t, start: UInt64)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Room for processes started between the two calls.
        size += size / 8
        let capacity = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var table: [pid_t: (ppid: pid_t, start: UInt64)] = [:]
        table.reserveCapacity(count)
        for proc in procs.prefix(count) {
            let started = proc.kp_proc.p_un.__p_starttime
            let start = UInt64(started.tv_sec) * 1_000_000 + UInt64(started.tv_usec)
            table[proc.kp_proc.p_pid] = (proc.kp_eproc.e_ppid, start)
        }
        return table
    }
    #else
    /// Every process's parent and start time (`/proc/<pid>/stat`).
    static func processTable() -> [pid_t: (ppid: pid_t, start: UInt64)] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        var table: [pid_t: (ppid: pid_t, start: UInt64)] = [:]
        for entry in entries {
            guard let pid = pid_t(entry),
                  let data = FileManager.default.contents(atPath: "/proc/\(pid)/stat"),
                  let stat = String(data: data, encoding: .utf8),
                  // The command name is parenthesised and may hold spaces;
                  // fields resume after the last ')'.
                  let close = stat.lastIndex(of: ")") else { continue }
            let fields = stat[stat.index(after: close)...].split(separator: " ")
            // fields[0] is the state (field 3): ppid is field 4, starttime 22.
            guard fields.count > 19,
                  let ppid = pid_t(fields[1]),
                  let start = UInt64(fields[19]) else { continue }
            table[pid] = (ppid, start)
        }
        return table
    }
    #endif
}
