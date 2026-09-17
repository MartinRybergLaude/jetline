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
    /// The terminal hosting the current (or most recent) run. Replaced on
    /// each `start` so a fresh script begins on a clean screen; the previous
    /// emulator is dropped along with its NSView.
    @Published private(set) var emulator: TerminalEmulatorView?

    var isRunning: Bool { phase != .idle }

    private var warmupItem: DispatchWorkItem?

    /// Set while a start is queued behind something else — an exclusive run
    /// waiting out the peers it displaces. The phase is already `.starting`,
    /// so the toolbar shows the queued run and Stop cancels it before
    /// anything spawns.
    private var pendingStart: Task<Void, Never>?

    /// Raw PTY bytes kept around for the copy button. Capped so a chatty
    /// `npm run dev` doesn't unbounded-grow memory; trim drops to 75% so we
    /// don't re-trim on every chunk.
    private var capturedBytes = Data()
    private let maxCapturedBytes = 200_000
    private let trimTargetBytes = 150_000

    /// `.starting` flips to `.running` once the process has stayed alive this
    /// long — proxy for "spawn actually took effect".
    private let startupGrace: TimeInterval = 1.0

    init(workspaceId: String) {
        self.workspaceId = workspaceId
    }

    func start(script: String, cwd: String, env: [String: String]) {
        guard phase == .idle, script.nonBlank != nil else { return }
        spawn(script: script, cwd: cwd, env: env)
    }

    /// Start once `clearance` resolves. Used by the exclusive-run path to
    /// wait until the peers it is displacing are really gone — a peer that
    /// ignores SIGHUP reports its exit immediately but can hold the port
    /// this run is about to bind until the force-kill lands.
    ///
    /// Goes to `.starting` up front so the queued run is visible and a
    /// second click stops it rather than starting a second copy.
    func start(
        script: String,
        cwd: String,
        env: [String: String],
        after clearance: @escaping @MainActor () async -> Void
    ) {
        guard phase == .idle, script.nonBlank != nil else { return }
        phase = .queued
        // Retire the previous run's surface now rather than when the new one
        // spawns. The panel renders whatever emulator this controller holds,
        // so leaving the old one in place shows a dead transcript — or, right
        // after a workspace switch, the terminal of the very run being
        // displaced — for as long as the queue takes.
        emulator?.nsView.removeFromSuperview()
        emulator = nil
        exitStatus = nil
        capturedBytes.removeAll(keepingCapacity: true)
        pendingStart = Task { @MainActor [weak self] in
            await clearance()
            guard let self, !Task.isCancelled else { return }
            self.pendingStart = nil
            self.spawn(script: script, cwd: cwd, env: env)
        }
    }

    private func spawn(script: String, cwd: String, env: [String: String]) {
        guard let trimmed = script.nonBlank else { return }

        let term = GhosttyEmulator(
            fontSize: GhosttyEmulator.outputPanelFontSize,
            notifySurfaceOnExit: false
        )
        term.setExitHandler { [weak self] code in
            Task { @MainActor [weak self] in self?.handleExit(code: code) }
        }

        capturedBytes.removeAll(keepingCapacity: true)
        exitStatus = nil
        phase = .starting
        // Drop the previous run's parked NSView so old emulators don't
        // accumulate in the incubator across repeated starts.
        emulator?.nsView.removeFromSuperview()
        emulator = term
        // Park before spawning so libghostty builds the surface — otherwise
        // PTY chunks that arrive before the panel mounts get dropped on the
        // floor by `InMemoryTerminalSession.receive` (surface == nil).
        // `setActive(false)` keeps the offscreen display link idle until
        // the panel adopts the view.
        TerminalIncubator.park(term.nsView)
        term.setActive(false)

        term.spawn(
            executable: ShellScriptLauncher.shell,
            args: ShellScriptLauncher.args(for: trimmed),
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

    /// Stop the run. SIGHUP via PTYProcess.terminate(), escalating to
    /// SIGKILL for anything still alive a moment later — the run script
    /// trampoline (`zsh -lic`) runs the script in a process group of its
    /// own, so terminate() signals that group alongside the shell's to
    /// catch every descendant.
    func stop() {
        if cancelPendingStart() { return }
        emulator?.terminate()
    }

    /// Stop, and wait until every process the run started is gone — not
    /// merely until the shell reported its exit. What the caller is usually
    /// waiting for is the port, and that outlives the exit when the job
    /// ignores SIGHUP.
    func stopAndWait() async {
        if cancelPendingStart() { return }
        guard let emulator else { return }
        await withCheckedContinuation { continuation in
            emulator.terminate { continuation.resume() }
        }
    }

    /// Drop a queued start and fall back to idle. Returns whether there was
    /// one, which is also "nothing has spawned, so there is nothing to
    /// signal".
    @discardableResult
    private func cancelPendingStart() -> Bool {
        guard let pending = pendingStart else { return false }
        pending.cancel()
        pendingStart = nil
        phase = .idle
        return true
    }

    /// Detach the emulator from the incubator and tear down its PTY. Used
    /// when the workspace is going away so the parked NSView doesn't
    /// outlive the controller.
    func discard() {
        // A queued start has to go too, or the workspace's teardown races a
        // process that hasn't spawned yet.
        cancelPendingStart()
        emulator?.terminate()
        emulator?.nsView.removeFromSuperview()
        emulator = nil
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
