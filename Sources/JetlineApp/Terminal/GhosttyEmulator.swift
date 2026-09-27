#if os(macOS)
import AppKit
import GhosttyTerminal

/// libghostty-backed terminal. Owns one `AppTerminalView` running against
/// an `InMemoryTerminalSession` whose I/O is bridged to an engine terminal
/// through a `TerminalChannel` — the PTY itself lives in the engine, which
/// may be this process or a remote `jetlined`. Replaces the SwiftTerm
/// renderer that mishandled DECSET 2026 (synchronized output) and produced
/// overdraw under Claude Code's flicker-free TUI.
@MainActor
final class GhosttyEmulator: TerminalEmulatorView {
    let view: AppTerminalView
    private let session: InMemoryTerminalSession
    private let controller: TerminalController
    private var channel: TerminalChannel?
    private var isActive: Bool = true
    private let receiveLogSessionId = TerminalReceiveLog.makeSessionId()

    var nsView: NSView { view }

    /// Run/setup output panels render with this size — smaller than the
    /// default 13pt agent terminal so the inspector strip doesn't crowd.
    static let outputPanelFontSize: Float = 11

    init(fontSize: Float = 13) {
        let controller = TerminalController(
            configuration: Self.makeConfiguration(family: nil, size: fontSize),
            theme: Self.theme
        )
        self.controller = controller

        let view = AppTerminalView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        self.view = view

        let link = ChannelHolder()
        let session = InMemoryTerminalSession(
            write: { data in
                link.write(data)
            },
            resize: { viewport in
                // Always record the viewport, even before a channel exists:
                // the surface is built (and its grid reported) while the view
                // sits in the incubator. `attach` sends it on, so the engine
                // spawns (or resizes) the process to the surface's real grid
                // — and libghostty dedupes resize dispatch, so a report
                // dropped here would never be re-sent.
                link.resize(viewport)
            }
        )
        self.session = session
        self.link = link

        view.controller = controller
        view.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session),
            context: .window
        )
    }

    /// Bridges the session's `@Sendable` callbacks (built before any channel
    /// exists) to the channel on the main actor, and remembers the latest
    /// viewport for the channel to pick up.
    private final class ChannelHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var _viewport: InMemoryTerminalViewport?
        nonisolated(unsafe) weak var channel: TerminalChannel?

        var viewport: InMemoryTerminalViewport? {
            lock.lock(); defer { lock.unlock() }
            return _viewport
        }

        func write(_ data: Data) {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.channel?.write(data) }
            }
        }

        func resize(_ viewport: InMemoryTerminalViewport) {
            lock.lock(); _viewport = viewport; lock.unlock()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.channel?.resize(viewport.terminalSize) }
            }
        }
    }
    private let link: ChannelHolder

    func attach(_ channel: TerminalChannel) {
        self.channel?.onOutput = nil
        self.channel = channel
        link.channel = channel
        let session = self.session
        let receiveLogSessionId = self.receiveLogSessionId
        channel.onOutput = { data in
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
        channel.onReset = {
            // RIS: full reset, so a replay from further on starts clean.
            session.receive(Data("\u{1B}c".utf8))
        }
        if let viewport = link.viewport {
            channel.resize(viewport.terminalSize)
        }
        channel.attach()
    }

    func sendInterrupt() {
        channel?.interrupt()
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        channel?.write(data)
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

    /// End the engine terminal behind this surface.
    func terminate() {
        channel?.close()
    }

    /// Stop receiving output (the engine terminal keeps running).
    func detach() {
        channel?.detach()
    }

    /// Resume output on a new link after a reconnect.
    func reattach() {
        channel?.attach()
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

private extension InMemoryTerminalViewport {
    var terminalSize: TerminalSize {
        TerminalSize(cols: columns, rows: rows, widthPx: widthPixels, heightPx: heightPixels)
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
#endif
