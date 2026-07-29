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
    private let receiveLogSessionId = TerminalReceiveLog.makeSessionId()
    /// When false, the emulator does *not* call `session.finish` on child
    /// exit. Jetline keeps terminal transcripts visible after exit and
    /// surfaces lifecycle state in host UI where needed; libghostty's own
    /// exit surface can obscure the final error output.
    private let notifySurfaceOnExit: Bool

    var nsView: NSView { view }

    /// Run/setup output panels render with this size — smaller than the
    /// default 13pt agent terminal so the inspector strip doesn't crowd.
    static let outputPanelFontSize: Float = 11

    init(fontSize: Float = 13, notifySurfaceOnExit: Bool = false) {
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
                // Always record the viewport, even with no process yet: the
                // surface is built (and its grid reported) while the view sits
                // in the incubator, before spawn. `spawn` reads this back so
                // the child's initial winsize matches the surface — and
                // libghostty dedupes resize dispatch, so a report dropped
                // here would never be re-sent once the process exists.
                pendingPTY.viewport = viewport
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
    /// writes/resizes to the eventual PTY. Also remembers the most recent
    /// viewport so `spawn` can size the forkpty winsize to the surface's
    /// real grid instead of the 80×24 default.
    private final class PTYHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _process: PTYProcess?
        private var _viewport: InMemoryTerminalViewport?

        var process: PTYProcess? {
            get { lock.lock(); defer { lock.unlock() }; return _process }
            set { lock.lock(); defer { lock.unlock() }; _process = newValue }
        }

        var viewport: InMemoryTerminalViewport? {
            get { lock.lock(); defer { lock.unlock() }; return _viewport }
            set { lock.lock(); defer { lock.unlock() }; _viewport = newValue }
        }
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
        let receiveLogSessionId = self.receiveLogSessionId
        TerminalReceiveLog.processStarted(sessionId: receiveLogSessionId, executable: executable, cwd: cwd)
        // Spawn with the surface's current grid as the initial winsize. The
        // surface reports its size before the process exists (the view is
        // parked in the incubator from birth), so without this the child
        // starts at 80×24 while the surface renders a different grid —
        // full-screen TUIs like Claude Code and Codex then draw for a
        // width the terminal doesn't have, leaving wrapped artifacts.
        let viewport = ptyHolder.viewport
        let pty = PTYProcess(
            executable: executable,
            args: args,
            cwd: cwd,
            env: environment,
            initialCols: viewport?.columns ?? 80,
            initialRows: viewport?.rows ?? 24,
            output: { data in
                // Hop to main before handing bytes to libghostty.
                // `InMemoryTerminalSession.receive` holds an NSLock across
                // `ghostty_surface_write_buffer`, which can take long enough on
                // a burst that a concurrent main-thread `dispatchResize` (fired
                // from an AppKit layout pass) wedges the watchdog. Running
                // receive on main serializes parse vs. resize on the same
                // thread, eliminating the contention. Tradeoff: heavy bursts
                // now share the main runloop. See PTYProcess.swift for the
                // drain source.
                DispatchQueue.main.async {
                    guard let receiveData = TerminalOutputFilter.removingTitleUpdates(data) else {
                        TerminalReceiveLog.droppedTitleUpdate(sessionId: receiveLogSessionId, data: data)
                        return
                    }
                    if receiveData.count != data.count {
                        TerminalReceiveLog.droppedTitleUpdate(sessionId: receiveLogSessionId, data: data)
                    }
                    let token = TerminalReceiveLog.begin(sessionId: receiveLogSessionId, data: receiveData)
                    session.receive(receiveData)
                    TerminalReceiveLog.end(token)
                }
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
            // Re-apply the latest viewport in case the grid changed between
            // reading it above and the process coming up — libghostty's
            // dispatch dedupes, so it won't re-send an unchanged grid now
            // that someone is listening. Same-size TIOCSWINSZ is a no-op.
            if let current = ptyHolder.viewport {
                pty.resize(
                    cols: current.columns,
                    rows: current.rows,
                    widthPx: current.widthPixels,
                    heightPx: current.heightPixels
                )
            }
        } catch {
            // Surface the failure as terminal output so the user sees something.
            let message = "jetline: failed to spawn \(executable): \(error)\r\n"
            TerminalReceiveLog.receiveFailed(sessionId: receiveLogSessionId, message: message)
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

    /// Terminal surface background, the single source of truth shared by the
    /// libghostty `theme` below (as hex) and the host-side padding strips in
    /// `TerminalDropContainer` (as `NSColor`). The padding inset only reads as
    /// "inside the terminal" while the strip colour matches the surface, so
    /// both consumers must derive from the same value.
    static let lightBackgroundHex = "FFFFFF"
    static let darkBackgroundHex = "1E1E1E"
    static let lightBackground = NSColor(ghosttyHex: lightBackgroundHex)
    static let darkBackground = NSColor(ghosttyHex: darkBackgroundHex)

    /// Aura-style palette: purple primary, mint/orange/pink/blue accents.
    /// Dark variant matches the source palette directly; the light variant
    /// preserves hue identity but darkens each accent for ≥4.5:1 contrast
    /// against a white background. `AppTerminalView` swaps `light`/`dark`
    /// automatically when the system appearance changes.
    ///
    /// ANSI mapping follows Aura's terminal config: blue→purple,
    /// magenta→pink, cyan→sky-blue. Unconventional, but it preserves all
    /// six accents distinctly across the 16-slot palette.
    private static let theme = TerminalTheme(
        light: TerminalConfiguration { builder in
            builder.withBackground(lightBackgroundHex)
            builder.withForeground("15141B")
            builder.withCursorColor("4A1FB8")
            builder.withSelectionBackground("DCD0FF")
            builder.withPalette(0, color: "#15141B")
            builder.withPalette(1, color: "#A30000")
            builder.withPalette(2, color: "#005C3D")
            builder.withPalette(3, color: "#6F4400")
            builder.withPalette(4, color: "#4A1FB8")
            builder.withPalette(5, color: "#7E2693")
            builder.withPalette(6, color: "#00558C")
            builder.withPalette(7, color: "#2D2D2D")
            builder.withPalette(8, color: "#6D6D6D")
            builder.withPalette(9, color: "#A30000")
            builder.withPalette(10, color: "#005C3D")
            builder.withPalette(11, color: "#6F4400")
            builder.withPalette(12, color: "#4A1FB8")
            builder.withPalette(13, color: "#7E2693")
            builder.withPalette(14, color: "#00558C")
            builder.withPalette(15, color: "#000000")
        },
        dark: TerminalConfiguration { builder in
            builder.withBackground(darkBackgroundHex)
            builder.withForeground("EDECEE")
            builder.withCursorColor("A277FF")
            builder.withSelectionBackground("29263C")
            builder.withPalette(0, color: "#15141B")
            builder.withPalette(1, color: "#FF6767")
            builder.withPalette(2, color: "#61FFCA")
            builder.withPalette(3, color: "#FFCA85")
            builder.withPalette(4, color: "#A277FF")
            builder.withPalette(5, color: "#F694FF")
            builder.withPalette(6, color: "#82E2FF")
            builder.withPalette(7, color: "#EDECEE")
            builder.withPalette(8, color: "#6D6D6D")
            builder.withPalette(9, color: "#FF6767")
            builder.withPalette(10, color: "#61FFCA")
            builder.withPalette(11, color: "#FFCA85")
            builder.withPalette(12, color: "#A277FF")
            builder.withPalette(13, color: "#F694FF")
            builder.withPalette(14, color: "#82E2FF")
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

private extension NSColor {
    /// Parses a 6-digit `RRGGBB` hex string (optional leading `#`), matching
    /// how libghostty interprets theme colours.
    convenience init(ghosttyHex hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
