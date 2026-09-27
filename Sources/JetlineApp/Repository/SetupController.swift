#if os(macOS)
import Foundation
import AppKit

/// The setup script's client side: mirrors the engine's setup `ScriptRun`
/// (started when a workspace is created) and renders its terminal in the
/// run panel.
@MainActor
final class SetupController: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case running
        case finished(exitCode: Int32)
    }

    let id = UUID().uuidString
    let workspaceId: String

    @Published private(set) var phase: Phase = .running
    @Published private(set) var emulator: TerminalEmulatorView?

    private let output = OutputCapture()
    private var terminalId: String?
    private weak var connection: EngineConnection?

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

    init(workspaceId: String, connection: EngineConnection) {
        self.workspaceId = workspaceId
        self.connection = connection
    }

    func apply(_ info: ScriptRunInfo) {
        let phase: Phase = info.phase == .finished ? .finished(exitCode: info.exitStatus ?? 0) : .running
        if self.phase != phase { self.phase = phase }
        guard info.terminalId != terminalId else { return }
        terminalId = info.terminalId
        emulator?.detach()
        emulator?.nsView.removeFromSuperview()
        emulator = nil
        output.clear()
        guard let terminalId = info.terminalId, let connection else { return }
        emulator = OutputTerminal.make(terminalId: terminalId, connection: connection, capture: output)
    }

    func reattach() {
        (emulator as? GhosttyEmulator)?.reattach()
    }

    func discard() {
        emulator?.detach()
        emulator?.nsView.removeFromSuperview()
        emulator = nil
    }

    func copyableOutput() -> String {
        TerminalText.stripControlSequences(output.text)
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
}
#endif
