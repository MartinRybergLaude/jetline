import Foundation
import AppKit

/// One-shot setup script runner. Spawned when a workspace is first created
/// and lives until the script exits. Output is rendered into a libghostty
/// emulator that the inspector's Run panel adopts before any run-script
/// runner exists, so the user can watch `npm install` (etc.) without being
/// blocked on the workspace-creation sheet.
@MainActor
final class SetupController: ObservableObject, Identifiable {
    enum Phase {
        case running
        case finished(exitCode: Int32)
    }

    let id = UUID().uuidString
    let workspaceId: String

    @Published private(set) var phase: Phase = .running
    @Published private(set) var emulator: TerminalEmulatorView?

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var didSucceed: Bool {
        if case let .finished(code) = phase { return code == 0 }
        return false
    }

    var exitCode: Int32? {
        if case let .finished(code) = phase { return code }
        return nil
    }

    private var capturedBytes = Data()
    private let maxCapturedBytes = 200_000
    private let trimTargetBytes = 150_000

    init(workspaceId: String) {
        self.workspaceId = workspaceId
    }

    func start(script: String, cwd: String, env: [String: String]) {
        guard case .running = phase, emulator == nil else { return }
        guard let trimmed = script.nonBlank else {
            phase = .finished(exitCode: 0)
            return
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let term = GhosttyEmulator(
            fontSize: GhosttyEmulator.outputPanelFontSize,
            notifySurfaceOnExit: false
        )
        term.setExitHandler { [weak self] code in
            Task { @MainActor [weak self] in self?.handleExit(code: code) }
        }
        emulator = term
        // Park before spawning so the surface exists when the first PTY
        // chunks arrive — see RunController.start for the full rationale.
        TerminalIncubator.park(term.nsView)
        term.setActive(false)
        term.spawn(
            executable: shell,
            args: ["-lc", trimmed],
            cwd: cwd,
            env: env,
            outputTap: { [weak self] data in
                Task { @MainActor [weak self] in self?.appendCapture(data) }
            }
        )
    }

    func terminate() {
        emulator?.terminate()
    }

    /// Tear the emulator down and pull its NSView out of the incubator.
    /// Used when the owning workspace is going away — `terminate()` alone
    /// would leave the parked view referencing nothing.
    func discard() {
        emulator?.terminate()
        emulator?.nsView.removeFromSuperview()
        emulator = nil
    }

    /// Plaintext output for the copy button, with terminal control sequences
    /// stripped. Reuses `RunController`'s helper so the two panels behave
    /// identically.
    func copyableOutput() -> String {
        let raw = String(data: capturedBytes, encoding: .utf8) ?? ""
        return RunController.stripControlSequences(raw)
    }

    @discardableResult
    func copyOutputToPasteboard() -> Bool {
        let text = copyableOutput()
        guard !text.isEmpty else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return true
    }

    private func handleExit(code: Int32) {
        guard case .running = phase else { return }
        phase = .finished(exitCode: code)
    }

    private func appendCapture(_ data: Data) {
        capturedBytes.append(data)
        if capturedBytes.count > maxCapturedBytes {
            let drop = capturedBytes.count - trimTargetBytes
            capturedBytes.removeFirst(drop)
        }
    }
}
