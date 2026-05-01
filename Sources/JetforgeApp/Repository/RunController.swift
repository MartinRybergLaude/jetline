import Foundation
import Combine

/// Long-running process started by the "Run" button on a workspace. Owns
/// the `Process`, tails stdout+stderr into `output`, and exposes `isRunning`
/// for the UI. One instance per active workspace; tracked by `AppState`.
@MainActor
final class RunController: ObservableObject, Identifiable {
    let id = UUID().uuidString
    let workspaceId: String

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var output: String = ""
    @Published private(set) var exitStatus: Int32?

    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private let onExit: @MainActor (RunController) -> Void

    /// ~200 KB cap so a chatty `npm run dev` doesn't unbounded-grow memory.
    private let maxOutputBytes = 200_000

    init(workspaceId: String, onExit: @escaping @MainActor (RunController) -> Void) {
        self.workspaceId = workspaceId
        self.onExit = onExit
    }

    func start(script: String, cwd: String, env: [String: String]) {
        guard !isRunning else { return }
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

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
        stdoutFH.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.appendAsync(data: data) }
        }
        stderrFH.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in self?.appendAsync(data: data) }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor in
                guard let self else { return }
                stdoutFH.readabilityHandler = nil
                stderrFH.readabilityHandler = nil
                self.process = nil
                self.isRunning = false
                self.exitStatus = p.terminationStatus
                self.onExit(self)
            }
        }

        do {
            try proc.run()
        } catch {
            output += "\nspawn failed: \(error)\n"
            return
        }

        self.process = proc
        self.stdoutHandle = stdoutFH
        self.stderrHandle = stderrFH
        self.isRunning = true
        self.exitStatus = nil
        self.output = ""
    }

    /// SIGTERM + grace period, then SIGKILL. Async because waiting on the
    /// process to exit synchronously would block the main actor.
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // Force-kill if it doesn't honour SIGTERM within 2s.
        let pid = proc.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            kill(pid, SIGKILL)
        }
    }

    private func appendAsync(data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        output.append(chunk)
        // Trim from the front so we stay under the cap. Keeps the tail —
        // which is what a user reading dev-server logs cares about.
        if output.utf8.count > maxOutputBytes {
            let overflow = output.utf8.count - maxOutputBytes
            if let idx = output.utf8.index(
                output.utf8.startIndex,
                offsetBy: overflow,
                limitedBy: output.utf8.endIndex
            ) {
                output = String(output[idx...])
            }
        }
    }
}
