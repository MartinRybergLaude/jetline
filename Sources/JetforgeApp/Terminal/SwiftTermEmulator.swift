import AppKit
import SwiftTerm

/// SwiftTerm-backed terminal. Two responsibilities the naive wiring got wrong:
///
/// 1. **Spawn timing.** `LocalProcessTerminalView.startProcess` snapshots the
///    view's current rows/cols when forking the PTY. If the view hasn't been
///    laid out yet (size 0×0), the child gets a zero-size PTY and silently
///    produces nothing — what you see is a blinking cursor and dead keys.
///    We stash the spawn intent and replay it after the view is in a window
///    AND has non-zero bounds.
///
/// 2. **First responder.** Embedded inside an NSViewRepresentable in a
///    NavigationSplitView, the terminal NSView never gets focus by default.
///    We force it on `viewDidMoveToWindow`.
@MainActor
final class SwiftTermEmulator: NSObject, TerminalEmulatorView, LocalProcessTerminalViewDelegate {
    private let view: JetforgeTerminalView

    var nsView: NSView { view }

    override init() {
        view = JetforgeTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    func spawn(executable: String, args: [String], cwd: String, env: [String: String]) {
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        let envArray = environment.map { "\($0.key)=\($0.value)" }

        view.scheduleSpawn(
            JetforgeTerminalView.SpawnRequest(
                executable: executable,
                args: args,
                env: envArray,
                cwd: cwd
            )
        )
    }

    func sendInterrupt() { view.send([0x03]) }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        view.send(Array(data))
    }

    func updateFont(family: String, size: CGFloat) {
        if let font = NSFont(name: family, size: size) {
            view.font = font
        } else {
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func terminate() { view.terminate() }

    // MARK: - LocalProcessTerminalViewDelegate
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// LocalProcessTerminalView subclass that defers spawn until the view is
/// actually visible and sized, and that auto-focuses on appear.
final class JetforgeTerminalView: LocalProcessTerminalView {
    struct SpawnRequest {
        let executable: String
        let args: [String]
        let env: [String]
        let cwd: String
    }

    private var pendingSpawn: SpawnRequest?
    private var hasSpawned = false

    func scheduleSpawn(_ req: SpawnRequest) {
        if hasSpawned { return }
        pendingSpawn = req
        attemptSpawn()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
            attemptSpawn()
        }
    }

    /// SwiftTerm uses `setFrameSize` (not `layout()`) for AutoLayout-driven
    /// sizing, so this is the hook that reliably fires once the view actually
    /// has bounds. `layout()` would silently never run for many constraint-
    /// managed view trees.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        attemptSpawn()
    }

    private func attemptSpawn() {
        guard let req = pendingSpawn, !hasSpawned else { return }
        guard window != nil, bounds.width > 16, bounds.height > 16 else { return }
        hasSpawned = true
        pendingSpawn = nil
        startProcess(
            executable: req.executable,
            args: req.args,
            environment: req.env,
            execName: nil,
            currentDirectory: req.cwd
        )
    }
}
