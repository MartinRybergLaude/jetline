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
    private var isActive: Bool = true
    private var exitHandler: ((Int32) -> Void)?
    /// When false, the emulator does *not* call `session.finish` on child
    /// exit. Used by run/setup output panels: the inspector already shows
    /// a "Setup complete" / "Exited (n)" status strip, so libghostty's
    /// own "Press any key to close" / "failed to launch" overlay is just
    /// noise — and worse, with our fixed `runtimeMilliseconds: 0` it
    /// renders as a launch failure even on a clean zero exit.
    private let notifySurfaceOnExit: Bool
    /// When true, `spawn()` stashes a deferred-start closure on `ptyHolder`
    /// instead of forking immediately. The first libghostty resize callback
    /// with a real viewport (cols ≥ 20, rows ≥ 5) triggers the actual fork
    /// using those dimensions as the initial winsize. Required for agent
    /// tabs: the term view starts life in `TerminalIncubator`'s 1×1 window,
    /// so an eager fork would hand the agent an 80×24 default tty and lock
    /// its TUI to that geometry before SwiftUI ever mounts the real tab.
    private let deferStartUntilSized: Bool

    var nsView: NSView { view }

    /// Run/setup output panels render with this size — smaller than the
    /// default 13pt agent terminal so the inspector strip doesn't crowd.
    static let outputPanelFontSize: Float = 11

    init(
        fontSize: Float = 13,
        notifySurfaceOnExit: Bool = true,
        deferStartUntilSized: Bool = false
    ) {
        self.notifySurfaceOnExit = notifySurfaceOnExit
        self.deferStartUntilSized = deferStartUntilSized
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
                pendingPTY.handleResize(
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
    /// writes/resizes to the eventual PTY. Also holds the deferred-start
    /// closure for agent tabs that wait for a real viewport before forking.
    private final class PTYHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _process: PTYProcess?
        private var pendingStart: ((UInt16, UInt16) -> PTYProcess?)?
        /// Last viewport reported by libghostty. Recorded for every callback
        /// (including pre-spawn ones) so a deferred `setPendingStart` arriving
        /// after the surface has already settled can fire immediately instead
        /// of waiting for a follow-up resize that may never come.
        private var lastViewport: Viewport?

        struct Viewport {
            let cols: UInt16
            let rows: UInt16
            let widthPx: UInt32
            let heightPx: UInt32
            var isReal: Bool { cols >= 20 && rows >= 5 }
        }

        var process: PTYProcess? {
            get { lock.lock(); defer { lock.unlock() }; return _process }
            set { lock.lock(); _process = newValue; lock.unlock() }
        }

        /// Park a deferred-start closure. If we've already observed a real
        /// viewport, claim the closure and fork now — this closes the race
        /// where libghostty's first sized-viewport callback lands while the
        /// caller is still awaiting its async setup work.
        func setPendingStart(_ start: @escaping (UInt16, UInt16) -> PTYProcess?) {
            lock.lock()
            if let v = lastViewport, v.isReal {
                lock.unlock()
                runStart(start, with: v)
            } else {
                pendingStart = start
                lock.unlock()
            }
        }

        func clearPendingStart() {
            lock.lock(); pendingStart = nil; lock.unlock()
        }

        /// Called from libghostty's resize thread for every viewport change.
        /// Routes to either the live PTY's `TIOCSWINSZ` or the deferred start
        /// (whichever applies), and always records the viewport for a future
        /// `setPendingStart` to consult.
        func handleResize(cols: UInt16, rows: UInt16, widthPx: UInt32, heightPx: UInt32) {
            let v = Viewport(cols: cols, rows: rows, widthPx: widthPx, heightPx: heightPx)
            lock.lock()
            lastViewport = v
            if let process = _process {
                lock.unlock()
                process.resize(cols: cols, rows: rows, widthPx: widthPx, heightPx: heightPx)
                return
            }
            if v.isReal, let start = pendingStart {
                pendingStart = nil
                lock.unlock()
                runStart(start, with: v)
                return
            }
            lock.unlock()
        }

        private func runStart(_ start: (UInt16, UInt16) -> PTYProcess?, with v: Viewport) {
            let pty = start(v.cols, v.rows)
            lock.lock(); _process = pty; lock.unlock()
            // forkpty's winsize ignored xpixel/ypixel — apply the real pixel
            // dims via TIOCSWINSZ so libghostty's sixel/image features and
            // any pixel-sensitive child code see correct values.
            pty?.resize(cols: v.cols, rows: v.rows, widthPx: v.widthPx, heightPx: v.heightPx)
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
        var mutableEnvironment = Subprocess.inheritedEnvironment(overrides: env)
        mutableEnvironment["TERM"] = mutableEnvironment["TERM"] ?? "xterm-256color"
        mutableEnvironment["COLORTERM"] = "truecolor"
        let environment = mutableEnvironment

        let session = self.session
        let holder = self.ptyHolder
        let notifyOnExit = self.notifySurfaceOnExit

        // Build the PTYProcess factory once, used either eagerly or by the
        // first real-viewport resize callback. Captures `holder` (sendable)
        // and hops to MainActor for emulator-state mutations.
        let build: @Sendable (UInt16, UInt16) -> PTYProcess? = { [weak self] cols, rows in
            let pty = PTYProcess(
                executable: executable,
                args: args,
                cwd: cwd,
                env: environment,
                initialCols: cols,
                initialRows: rows,
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
                        session.receive(data)
                    }
                    outputTap?(data)
                },
                exit: { exitCode in
                    Task { @MainActor [weak self] in
                        if notifyOnExit {
                            session.finish(
                                exitCode: UInt32(clamping: exitCode),
                                runtimeMilliseconds: 0
                            )
                        }
                        self?.exitHandler?(exitCode)
                        // Drop PTYProcess only after exit is reported. If we
                        // freed it inside `terminate()`, the dispatch source's
                        // cancel handler (weak-self) would never fire and
                        // exit would silently never be delivered.
                        holder.process = nil
                    }
                }
            )

            do {
                try pty.start()
                return pty
            } catch {
                let message = "jetline: failed to spawn \(executable): \(error)\r\n"
                session.receive(message)
                return nil
            }
        }

        if deferStartUntilSized {
            // Park the build closure; the first real-viewport resize from
            // libghostty will atomically claim and run it (see PTYHolder).
            holder.setPendingStart(build)
        } else {
            holder.process = build(80, 24)
        }
    }

    func setExitHandler(_ handler: @escaping (Int32) -> Void) {
        exitHandler = handler
    }

    func sendInterrupt() {
        ptyHolder.process?.interrupt()
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        ptyHolder.process?.write(data)
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
            builder.withBackground("FFFFFF")
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
            builder.withBackground("1E1E1E")
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
        // Drop a deferred-start that never fired so closing a tab before its
        // viewport ever resolved doesn't leak a half-configured spawn.
        ptyHolder.clearPendingStart()
        // The `process = nil` cleanup is deferred to the exit closure —
        // see spawn.
        ptyHolder.process?.terminate()
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
