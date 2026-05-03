import AppKit
import GhosttyTerminal

/// libghostty-backed terminal. Owns one `AppTerminalView` running against
/// an `InMemoryTerminalSession` whose I/O is bridged to a real PTY managed
/// by `PTYProcess`. Replaces the SwiftTerm renderer that mishandled
/// DECSET 2026 (synchronized output) and produced overdraw under
/// Claude Code's flicker-free TUI.
@MainActor
final class GhosttyEmulator: TerminalEmulatorView {
    let view: AppTerminalView
    private let session: InMemoryTerminalSession
    private let controller: TerminalController
    private var pty: PTYProcess?
    private var isActive: Bool = true
    private var exitHandler: ((Int32) -> Void)?

    var nsView: NSView { view }

    init() {
        let controller = TerminalController(
            configuration: Self.makeConfiguration(family: nil, size: 13)
        )
        self.controller = controller

        let view = AppTerminalView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        self.view = view

        let pendingPTY = PTYHolder()
        let session = InMemoryTerminalSession(
            write: { data in
                pendingPTY.process?.write(data)
            },
            resize: { viewport in
                pendingPTY.process?.resize(
                    cols: viewport.columns,
                    rows: viewport.rows,
                    widthPx: viewport.widthPixels,
                    heightPx: viewport.heightPixels
                )
            }
        )
        self.session = session
        self.ptyHolder = pendingPTY

        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            context: .window
        )
    }

    /// Captures the PTY reference so the InMemoryTerminalSession's
    /// `@Sendable` closures (constructed before `pty` exists) can route
    /// writes/resizes to the eventual PTY.
    private final class PTYHolder: @unchecked Sendable {
        var process: PTYProcess?
    }
    private let ptyHolder: PTYHolder

    func spawn(executable: String, args: [String], cwd: String, env: [String: String]) {
        var environment = Subprocess.inheritedEnvironment(overrides: env)
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["COLORTERM"] = "truecolor"

        let session = self.session
        let pty = PTYProcess(
            executable: executable,
            args: args,
            cwd: cwd,
            env: environment,
            output: { data in
                session.receive(data)
            },
            exit: { [weak self] exitCode in
                Task { @MainActor in
                    session.finish(exitCode: UInt32(clamping: exitCode), runtimeMilliseconds: 0)
                    self?.exitHandler?(exitCode)
                }
            }
        )

        do {
            try pty.start()
            self.pty = pty
            ptyHolder.process = pty
        } catch {
            // Surface the failure as terminal output so the user sees something.
            let message = "jetline: failed to spawn \(executable): \(error)\r\n"
            session.receive(message)
        }
    }

    func setExitHandler(_ handler: @escaping (Int32) -> Void) {
        exitHandler = handler
    }

    func sendInterrupt() {
        pty?.interrupt()
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        pty?.write(data)
    }

    func updateFont(family: String, size: CGFloat) {
        controller.setTerminalConfiguration(
            Self.makeConfiguration(family: family, size: Float(size))
        )
    }

    private static func makeConfiguration(family: String?, size: Float) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            if let family { builder.withFontFamily(family) }
            builder.withFontSize(size)
        }
    }

    func terminate() {
        pty?.terminate()
        pty = nil
        ptyHolder.process = nil
    }

    /// Drive Metal rendering only when the tab is active; an inactive tab's
    /// `CAMetalLayer` would otherwise keep firing on display refresh.
    /// Guarded so SwiftUI's per-update churn doesn't ping the surface
    /// every layout pass.
    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        view.setSurfaceVisible(active)
    }
}
