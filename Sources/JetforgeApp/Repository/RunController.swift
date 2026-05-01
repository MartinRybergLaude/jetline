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
    private var killWorkItem: DispatchWorkItem?
    private let onExit: @MainActor (RunController) -> Void

    /// ~200 KB cap so a chatty `npm run dev` doesn't unbounded-grow memory.
    /// Trim drops to 75% so we don't re-trim on every chunk.
    private let maxOutputBytes = 200_000
    private let trimTargetBytes = 150_000
    /// Tracked alongside `output` so we don't pay an O(n) `utf8.count` walk per chunk.
    private var outputBytes = 0

    init(workspaceId: String, onExit: @escaping @MainActor (RunController) -> Void) {
        self.workspaceId = workspaceId
        self.onExit = onExit
    }

    func start(script: String, cwd: String, env: [String: String]) {
        guard !isRunning, let trimmed = script.nonBlank else { return }

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
                self.process = nil
                self.isRunning = false
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
        self.isRunning = true
    }

    /// SIGTERM + 2s grace, then SIGKILL — but only if the process is still
    /// alive. Cancelling on terminationHandler avoids killing a recycled pid.
    func stop() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        let item = DispatchWorkItem { [weak proc] in
            guard let proc, proc.isRunning else { return }
            kill(proc.processIdentifier, SIGKILL)
        }
        killWorkItem?.cancel()
        killWorkItem = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: item)
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
