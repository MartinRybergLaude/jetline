import Foundation
import Combine
import AppKit

/// Long-running process started by the "Run" button on a workspace. Owns
/// a libghostty-backed terminal emulator that renders the script's output
/// directly inside the inspector, plus a parallel byte buffer captured for
/// the panel's "copy" button. One instance per active workspace; tracked by
/// `AppState`.
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
    @Published private(set) var exitStatus: Int32?
    /// The terminal hosting the current (or most recent) run. Replaced on
    /// each `start` so a fresh script begins on a clean screen; the previous
    /// emulator is dropped along with its NSView.
    @Published private(set) var emulator: TerminalEmulatorView?

    var isRunning: Bool { phase != .idle }

    private var warmupItem: DispatchWorkItem?
    private let onExit: @MainActor (RunController) -> Void

    /// Raw PTY bytes kept around for the copy button. Capped so a chatty
    /// `npm run dev` doesn't unbounded-grow memory; trim drops to 75% so we
    /// don't re-trim on every chunk.
    private var capturedBytes = Data()
    private let maxCapturedBytes = 200_000
    private let trimTargetBytes = 150_000

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
        let term = GhosttyEmulator()
        term.setExitHandler { [weak self] code in
            Task { @MainActor [weak self] in self?.handleExit(code: code) }
        }

        capturedBytes.removeAll(keepingCapacity: true)
        exitStatus = nil
        phase = .starting
        emulator = term

        term.spawn(
            executable: shell,
            args: ["-lc", trimmed],
            cwd: cwd,
            env: env,
            outputTap: { [weak self] data in
                Task { @MainActor [weak self] in self?.appendCapture(data) }
            }
        )

        let warmup = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .starting else { return }
                self.phase = .running
            }
        }
        self.warmupItem = warmup
        DispatchQueue.main.asyncAfter(deadline: .now() + startupGrace, execute: warmup)
    }

    /// Stop the run. SIGKILL via PTYProcess.terminate() — the run script
    /// trampoline (`zsh -lc`) puts the script in its own process group, so
    /// killing the group catches every descendant.
    func stop() {
        emulator?.terminate()
    }

    /// Plaintext bytes for the copy button, with terminal control sequences
    /// stripped so the clipboard doesn't carry `\x1b[…m` noise.
    func copyableOutput() -> String {
        let raw = String(data: capturedBytes, encoding: .utf8) ?? ""
        return Self.stripControlSequences(raw)
    }

    /// Place the current copyable output on the general pasteboard.
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
        guard phase != .idle else { return }
        warmupItem?.cancel()
        warmupItem = nil
        phase = .idle
        exitStatus = code
        onExit(self)
    }

    private func appendCapture(_ data: Data) {
        capturedBytes.append(data)
        if capturedBytes.count > maxCapturedBytes {
            let drop = capturedBytes.count - trimTargetBytes
            capturedBytes.removeFirst(drop)
        }
    }

    /// Strip CSI / OSC / single-char ESC sequences and collapse `\r\n` to
    /// `\n`. Keeps printable text + `\n` + `\t` so copy/paste from a long
    /// run is readable. Standalone `\r` (carriage return without newline,
    /// used by progress bars to redraw a line) becomes a newline so the
    /// clipboard shows the redraws as separate lines instead of overlap.
    static func stripControlSequences(_ s: String) -> String {
        var out = String()
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            switch c {
            case "\u{1B}":
                let next = s.index(after: i)
                guard next < s.endIndex else { return out }
                let n = s[next]
                if n == "[" {
                    // CSI: ESC [ params final-byte (0x40-0x7E)
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        let cc = s[j]
                        j = s.index(after: j)
                        if let ascii = cc.asciiValue, ascii >= 0x40, ascii <= 0x7E { break }
                    }
                    i = j
                } else if n == "]" {
                    // OSC: ESC ] ... BEL  or  ESC ] ... ESC \
                    var j = s.index(after: next)
                    while j < s.endIndex {
                        if s[j] == "\u{07}" { j = s.index(after: j); break }
                        if s[j] == "\u{1B}" {
                            let after = s.index(after: j)
                            if after < s.endIndex, s[after] == "\\" {
                                j = s.index(after: after); break
                            }
                        }
                        j = s.index(after: j)
                    }
                    i = j
                } else {
                    // Two-byte ESC sequences (e.g. character-set selection).
                    i = s.index(after: next)
                }
            case "\r":
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "\n" {
                    out.append("\n"); i = s.index(after: next)
                } else {
                    out.append("\n"); i = next
                }
            case "\u{07}", "\u{08}":
                // BEL and BS — drop, they don't survive a copy meaningfully.
                i = s.index(after: i)
            default:
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }
}
