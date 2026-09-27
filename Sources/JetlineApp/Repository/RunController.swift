#if os(macOS)
import Foundation
import AppKit

/// The run script's client side: mirrors the engine's `ScriptRun` for the
/// toolbar and run panel, and renders its terminal. The process itself runs
/// in the engine; Run/Stop go through `AppState.toggleRun`.
@MainActor
final class RunController: ObservableObject, Identifiable {
    enum Phase {
        case idle
        /// Started, but held behind the exclusive peers it is displacing.
        /// No process yet — and no surface, so the panel can't show the run
        /// this one is replacing.
        case queued
        case starting
        case running
    }

    let id = UUID().uuidString
    let workspaceId: String

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var exitStatus: Int32?
    /// The terminal showing the current (or most recent) run. Replaced when
    /// the engine starts a new run, so each begins on a clean screen.
    @Published private(set) var emulator: TerminalEmulatorView?

    private let output = OutputCapture()
    private var terminalId: String?
    private weak var connection: EngineConnection?

    var isRunning: Bool { phase != .idle }

    init(workspaceId: String, connection: EngineConnection) {
        self.workspaceId = workspaceId
        self.connection = connection
    }

    func apply(_ info: ScriptRunInfo) {
        let phase: Phase
        switch info.phase {
        case .idle, .finished: phase = .idle
        case .queued: phase = .queued
        case .starting: phase = .starting
        case .running: phase = .running
        }
        if self.phase != phase { self.phase = phase }
        if exitStatus != info.exitStatus { exitStatus = info.exitStatus }
        guard info.terminalId != terminalId else { return }
        terminalId = info.terminalId
        emulator?.detach()
        emulator?.nsView.removeFromSuperview()
        emulator = nil
        output.clear()
        guard let terminalId = info.terminalId, let connection else { return }
        emulator = OutputTerminal.make(terminalId: terminalId, connection: connection, capture: output)
    }

    /// Re-attach after a reconnect.
    func reattach() {
        (emulator as? GhosttyEmulator)?.reattach()
    }

    /// Drop the surface (the workspace closed).
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

    static func stripControlSequences(_ s: String) -> String {
        TerminalText.stripControlSequences(s)
    }
}

/// Recent raw output kept for the copy button. Capped so a chatty
/// `npm run dev` doesn't grow memory without bound.
final class OutputCapture {
    private var bytes = Data()
    private let maxBytes = 200_000
    private let trimTarget = 150_000

    func append(_ data: Data) {
        bytes.append(data)
        if bytes.count > maxBytes {
            bytes.removeFirst(bytes.count - trimTarget)
        }
    }

    func clear() { bytes.removeAll(keepingCapacity: true) }

    var text: String { String(decoding: bytes, as: UTF8.self) }
}

/// A run/setup output surface: smaller font, parked in the incubator so it
/// renders output even while the panel is closed.
@MainActor
enum OutputTerminal {
    static func make(terminalId: String, connection: EngineConnection, capture: OutputCapture) -> TerminalEmulatorView {
        let term = GhosttyEmulator(fontSize: GhosttyEmulator.outputPanelFontSize)
        TerminalIncubator.park(term.nsView)
        term.setActive(false)
        let channel = TerminalChannel(terminalId: terminalId, connection: connection)
        channel.tap = { capture.append($0) }
        term.attach(channel)
        return term
    }
}
#endif
