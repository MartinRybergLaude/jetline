import Foundation
import Combine
import Darwin

/// Long-running process started by the "Run" button on a workspace. Owns
/// the `Process`, tails stdout+stderr into `output`, and exposes `phase`
/// for the UI. One instance per active workspace; tracked by `AppState`.
@MainActor
final class RunController: ObservableObject, Identifiable {
    enum Phase {
        case idle
        case starting
        case running
    }

    let id = UUID().uuidString
    let workspaceId: String

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var output: String = ""
    @Published private(set) var exitStatus: Int32?

    var isRunning: Bool { phase != .idle }

    private var process: Process?
    private var killWorkItem: DispatchWorkItem?
    private var warmupItem: DispatchWorkItem?
    private let onExit: @MainActor (RunController) -> Void

    /// ~200 KB cap so a chatty `npm run dev` doesn't unbounded-grow memory.
    /// Trim drops to 75% so we don't re-trim on every chunk.
    private let maxOutputBytes = 200_000
    private let trimTargetBytes = 150_000
    /// Tracked alongside `output` so we don't pay an O(n) `utf8.count` walk per chunk.
    private var outputBytes = 0

    /// `.starting` flips to `.running` once the process has stayed alive this
    /// long — proxy for "spawn actually took effect".
    private let startupGrace: TimeInterval = 1.0

    init(workspaceId: String, onExit: @escaping @MainActor (RunController) -> Void) {
        self.workspaceId = workspaceId
        self.onExit = onExit
    }

    func start(script: String, cwd: String, env: [String: String]) {
        guard phase == .idle, let trimmed = script.nonBlank else { return }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", trimmed]
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        proc.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice

        let stdoutFH = outPipe.fileHandleForReading
        let stderrFH = errPipe.fileHandleForReading
        // Pipe handlers fire on a background thread; hop to main before
        // touching `output` (a @MainActor-isolated @Published).
        let pipeHandler: @Sendable (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.appendAsync(data: data) }
        }
        stdoutFH.readabilityHandler = pipeHandler
        stderrFH.readabilityHandler = pipeHandler

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                stdoutFH.readabilityHandler = nil
                stderrFH.readabilityHandler = nil
                // Cancel any pending SIGKILL — we already exited.
                self.killWorkItem?.cancel()
                self.killWorkItem = nil
                self.warmupItem?.cancel()
                self.warmupItem = nil
                self.process = nil
                self.phase = .idle
                self.exitStatus = p.terminationStatus
                self.onExit(self)
            }
        }

        output = ""
        outputBytes = 0
        exitStatus = nil

        do {
            try proc.run()
        } catch {
            output = "spawn failed: \(error)\n"
            outputBytes = output.utf8.count
            return
        }

        self.process = proc
        self.phase = .starting

        let warmup = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .starting else { return }
                self.phase = .running
            }
        }
        self.warmupItem = warmup
        DispatchQueue.main.asyncAfter(deadline: .now() + startupGrace, execute: warmup)
    }

    /// SIGTERM the whole process tree, then SIGKILL anything still alive
    /// after a short grace. Foundation's `Process.terminate()` only signals
    /// the shell we spawned — long-running scripts (e.g. `npm run dev`) fork
    /// children that survive the shell exit, so we walk descendants from `ps`
    /// and signal them too.
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        let pid = proc.processIdentifier
        let descendants = Self.descendantPids(of: pid)

        // Children first, parent last.
        for d in descendants.reversed() { kill(d, SIGTERM) }
        proc.terminate()

        let item = DispatchWorkItem { [weak proc] in
            for d in descendants.reversed() { kill(d, SIGKILL) }
            if let proc, proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        killWorkItem?.cancel()
        killWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    /// BFS over `ps -A` output to collect every transitive descendant of `root`.
    /// Snapshot-at-stop-time — children that fork after this call won't be
    /// caught, but in practice that's rare for "Run" scripts.
    private static func descendantPids(of root: pid_t) -> [pid_t] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pid=,ppid="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        var byParent: [pid_t: [pid_t]] = [:]
        let str = String(decoding: data, as: UTF8.self)
        for line in str.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " }).filter { !$0.isEmpty }
            guard parts.count >= 2,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            byParent[ppid, default: []].append(pid)
        }

        var result: [pid_t] = []
        var queue = [root]
        while !queue.isEmpty {
            let p = queue.removeFirst()
            if let kids = byParent[p] {
                result.append(contentsOf: kids)
                queue.append(contentsOf: kids)
            }
        }
        return result
    }

    private func appendAsync(data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        output.append(chunk)
        outputBytes += chunk.utf8.count
        guard outputBytes > maxOutputBytes else { return }
        let drop = outputBytes - trimTargetBytes
        if let idx = output.utf8.index(
            output.utf8.startIndex,
            offsetBy: drop,
            limitedBy: output.utf8.endIndex
        ) {
            output = String(output[idx...])
            outputBytes = output.utf8.count
        }
    }
}
