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
    /// When false, the emulator does *not* call `session.finish` on child
    /// exit. Used by run/setup output panels: the inspector already shows
    /// a "Setup complete" / "Exited (n)" status strip, so libghostty's
    /// own "Press any key to close" / "failed to launch" overlay is just
    /// noise — and worse, with our fixed `runtimeMilliseconds: 0` it
    /// renders as a launch failure even on a clean zero exit.
    private let notifySurfaceOnExit: Bool

    var nsView: NSView { view }

    /// Run/setup output panels render with this size — smaller than the
    /// default 13pt agent terminal so the inspector strip doesn't crowd.
    static let outputPanelFontSize: Float = 11

    init(fontSize: Float = 13, notifySurfaceOnExit: Bool = true) {
        self.notifySurfaceOnExit = notifySurfaceOnExit
        let controller = TerminalController(
            configuration: Self.makeConfiguration(family: nil, size: fontSize),
            theme: Self.theme
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

    func spawn(
        executable: String,
        args: [String],
        cwd: String,
        env: [String: String],
        outputTap: (@Sendable (Data) -> Void)? = nil
    ) {
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
                outputTap?(data)
            },
            exit: { [weak self] exitCode in
                Task { @MainActor in
                    if self?.notifySurfaceOnExit ?? true {
                        session.finish(exitCode: UInt32(clamping: exitCode), runtimeMilliseconds: 0)
                    }
                    self?.exitHandler?(exitCode)
                    // Drop PTYProcess only after exit is reported. If we
                    // freed it inside `terminate()`, the dispatch source's
                    // cancel handler (weak-self) would never fire and
                    // exit would silently never be delivered.
                    self?.pty = nil
                    self?.ptyHolder.process = nil
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

    /// Route through libghostty's `paste_from_clipboard` action so the
    /// surface adds the DECSET-2004 brackets when the host program is in
    /// bracketed-paste mode (Claude Code, modern shells, etc.). libghostty's
    /// only public paste path reads from the system clipboard, so we
    /// trample it for the synchronous paste roundtrip and put the original
    /// contents back. The `read_clipboard` callback fires synchronously
    /// inside `performBindingAction`, so the restore that follows is safe.
    func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> (NSPasteboard.PasteboardType, Data)? in
            guard let type = item.types.first(where: { $0 == .string }),
                  let data = item.data(forType: type) else { return nil }
            return (type, data)
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        view.performBindingAction("paste_from_clipboard")
        pasteboard.clearContents()
        if let saved {
            for (type, data) in saved {
                pasteboard.setData(data, forType: type)
            }
        }
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

    /// Pure black/white backgrounds with saturated jewel-tone palettes —
    /// punchier than libghostty's default Afterglow/Alabaster pair.
    /// `AppTerminalView` swaps `light`/`dark` automatically when the system
    /// appearance changes.
    private static let theme = TerminalTheme(
        light: TerminalConfiguration { builder in
            builder.withBackground("FFFFFF")
            builder.withForeground("000000")
            builder.withCursorColor("000000")
            builder.withSelectionBackground("A6CFFF")
            builder.withPalette(0, color: "#000000")
            builder.withPalette(1, color: "#C20000")
            builder.withPalette(2, color: "#087A00")
            builder.withPalette(3, color: "#8B6500")
            builder.withPalette(4, color: "#0040C0")
            builder.withPalette(5, color: "#A300A3")
            builder.withPalette(6, color: "#00808F")
            builder.withPalette(7, color: "#5C5C5C")
            builder.withPalette(8, color: "#8C8C8C")
            builder.withPalette(9, color: "#E80000")
            builder.withPalette(10, color: "#00A300")
            builder.withPalette(11, color: "#A37A00")
            builder.withPalette(12, color: "#0066D9")
            builder.withPalette(13, color: "#D900D9")
            builder.withPalette(14, color: "#008CA3")
            builder.withPalette(15, color: "#1A1A1A")
        },
        dark: TerminalConfiguration { builder in
            builder.withBackground("1E1E1E")
            builder.withForeground("FFFFFF")
            builder.withCursorColor("FFFFFF")
            builder.withSelectionBackground("244779")
            builder.withPalette(0, color: "#000000")
            builder.withPalette(1, color: "#FF5555")
            builder.withPalette(2, color: "#50FA7B")
            builder.withPalette(3, color: "#F1FA8C")
            builder.withPalette(4, color: "#5C9CFF")
            builder.withPalette(5, color: "#FF79C6")
            builder.withPalette(6, color: "#8BE9FD")
            builder.withPalette(7, color: "#F8F8F2")
            builder.withPalette(8, color: "#6272A4")
            builder.withPalette(9, color: "#FF6E6E")
            builder.withPalette(10, color: "#69FF94")
            builder.withPalette(11, color: "#FFFFA5")
            builder.withPalette(12, color: "#7DA9FF")
            builder.withPalette(13, color: "#FF92DF")
            builder.withPalette(14, color: "#A4FFFF")
            builder.withPalette(15, color: "#FFFFFF")
        }
    )

    func terminate() {
        // The `pty = nil` cleanup is deferred to the exit closure — see spawn.
        pty?.terminate()
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
