#if os(macOS)
import Foundation

/// A Ghostty surface's line to one engine terminal. Output arrives in
/// offset order; the channel remembers how far it got, so re-attaching
/// after a reconnect replays exactly what was missed. A jump in offsets
/// means bytes fell out of the engine's buffer — the screen is reset before
/// the rest is drawn, since half an escape sequence would corrupt it.
@MainActor
final class TerminalChannel {
    let terminalId: String
    private weak var connection: EngineConnection?
    private var client: EngineClient?
    /// Next offset expected; nil before the first byte.
    private var expected: UInt64?
    private var lastSize: TerminalSize?
    private var pendingResize: Task<Void, Never>?

    var onOutput: ((Data) -> Void)?
    /// A second listener for the same bytes (the run panel's copy buffer).
    var tap: ((Data) -> Void)?
    /// Clear the screen: what follows is a replay from further on.
    var onReset: (() -> Void)?

    init(terminalId: String, connection: EngineConnection) {
        self.terminalId = terminalId
        self.connection = connection
    }

    /// Start (or resume) receiving output. Safe to call again after a
    /// reconnect — it re-subscribes on the new link.
    func attach() {
        guard let connection, connection.isConnected, let client = connection.client else { return }
        self.client?.setTerminalHandler(terminalId, nil)
        self.client = client
        client.setTerminalHandler(terminalId) { [weak self] offset, bytes in
            self?.receive(offset: offset, bytes: bytes)
        }
        let id = terminalId
        let from = expected
        Task {
            _ = try? await client.call(API.AttachTerminal(terminalId: id, fromOffset: from))
        }
        if let lastSize {
            client.send(API.ResizeTerminal(terminalId: id, size: lastSize))
        }
    }

    func detach() {
        client?.setTerminalHandler(terminalId, nil)
        client?.send(API.DetachTerminal(terminalId: terminalId))
        client = nil
    }

    private func receive(offset: UInt64, bytes: Data) {
        var bytes = bytes
        var offset = offset
        if let expected {
            if offset + UInt64(bytes.count) <= expected { return }
            if offset < expected {
                bytes = bytes.subdata(in: (bytes.startIndex + Int(expected - offset))..<bytes.endIndex)
                offset = expected
            } else if offset > expected {
                onReset?()
            }
        }
        expected = offset + UInt64(bytes.count)
        onOutput?(bytes)
        tap?(bytes)
    }

    func write(_ data: Data) {
        client?.sendTerminalInput(terminalId, data)
    }

    /// Resizes are coalesced: a window drag reports every intermediate grid.
    func resize(_ size: TerminalSize) {
        guard size != lastSize else { return }
        lastSize = size
        pendingResize?.cancel()
        let id = terminalId
        pendingResize = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled, let self else { return }
            self.client?.send(API.ResizeTerminal(terminalId: id, size: size))
        }
    }

    func interrupt() {
        client?.send(API.InterruptTerminal(terminalId: terminalId))
    }

    /// End the terminal's process and drop the tab engine-side.
    func close() {
        client?.send(API.CloseTerminal(terminalId: terminalId))
        detach()
    }

    func copyableText() async -> String {
        guard let connection else { return "" }
        return (try? await connection.call(API.TerminalText(terminalId: terminalId))) ?? ""
    }
}
#endif
