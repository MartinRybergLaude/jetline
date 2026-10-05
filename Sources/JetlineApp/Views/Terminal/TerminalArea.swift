#if os(macOS)
import SwiftUI
import AppKit

struct TerminalArea: View {
    @Environment(\.colorScheme) private var colorScheme
    let workspace: Workspace
    /// Per-workspace state (sessions, diff stats, run/setup controllers).
    /// `@Observable` so reads tracked per-keypath — a poll landing on a
    /// *different* workspace doesn't invalidate the terminal area, and
    /// within this view a `pr` update doesn't invalidate the parts that
    /// only read `sessions`.
    let workspaceState: WorkspaceState

    /// The window tab this view fills. Its `tab` picks the content; the
    /// native tab bar above belongs to AppKit.
    let slot: TabSlot

    /// The session whose terminal is currently mounted. Trails the slot's
    /// tab during rapid keyboard navigation (⌘⇧↑/↓ workspace cycling
    /// reassigns the visible window's tab on every hop): every mount/unmount
    /// costs two ghostty surface reflows plus a SIGWINCH-driven TUI redraw,
    /// so remounting on each hop makes held-key navigation crawl. A single
    /// switch applies immediately; only switches arriving within
    /// `rapidSwitchWindow` of the previous one blank the surface and settle
    /// after `settleDelay`.
    @State private var displayedSession: PTYSession?
    @State private var displaySettleTask: Task<Void, Never>?
    @State private var lastSessionSwitch: ContinuousClock.Instant?

    private static let rapidSwitchWindow: Duration = .milliseconds(350)
    private static let settleDelay: Duration = .milliseconds(120)

    var body: some View {
        tabContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: slotSession?.id, initial: true) {
            syncDisplayedSession()
        }
        .onChange(of: slot.hasBeenShown) {
            syncDisplayedSession()
        }
        .onChange(of: tabTitle, initial: true) { _, title in
            // An empty slot is named by the coordinator.
            guard slot.tab != nil else { return }
            slot.window?.tab.attributedTitle = TabTitle.attributed(icon: title.icon, title: title.text)
        }
        .mergeConfirmation(workspace: workspace, isPresented: Bindable(slot).pendingMerge)
    }

    /// Placeholder until the slot is first selected — background tabs don't
    /// mount terminals or chats nobody has looked at yet.
    @ViewBuilder
    private var tabContent: some View {
        if !slot.hasBeenShown {
            Color(nsColor: .textBackgroundColor)
        } else {
            switch slot.tab {
            case .diff(let id):
                if let tab = workspaceState.diffTabs.first(where: { $0.id == id }) {
                    FileDiffView(workspace: workspace, workspaceState: workspaceState, tab: tab)
                        .id(tab.id)
                }
            case .chat(let id):
                if let chat = workspaceState.chats.first(where: { $0.id == id }) {
                    ChatView(session: chat)
                        .id(chat.id)
                }
            case .session:
                terminalSurface
            case .launcher(let id):
                NewTabPage(workspace: workspace, launcherId: id)
            case nil:
                ProgressView()
            }
        }
    }

    private var slotSession: PTYSession? {
        guard case .session(let id) = slot.tab else { return nil }
        return workspaceState.sessions.first { $0.id == id }
    }

    private static let launcherIcon = NSImage(systemSymbolName: "plus.square.on.square", accessibilityDescription: nil)

    private struct NativeTabTitle: Equatable {
        let text: String
        let icon: NSImage?
    }

    /// What the native tab shows for this slot.
    private var tabTitle: NativeTabTitle {
        switch slot.tab {
        case .session:
            let agent = slotSession?.agent ?? .shell
            return NativeTabTitle(text: agent.displayName, icon: AgentMark.image(for: agent))
        case .chat(let id):
            let chat = workspaceState.chats.first { $0.id == id }
            return NativeTabTitle(
                text: chat?.title ?? "Chat",
                icon: chat.flatMap { AgentMark.image(for: $0.provider.agentKind) }
            )
        case .diff(let id):
            return NativeTabTitle(
                text: (id as NSString).lastPathComponent,
                icon: TabTitle.fileIcon(for: id)
            )
        case .launcher:
            return NativeTabTitle(text: "New Tab", icon: Self.launcherIcon)
        case nil:
            return NativeTabTitle(text: workspace.name, icon: nil)
        }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let session = displayedSession {
            SessionSurface(session: session, isActive: slot.isSelected)
                .id(session.id)
        } else if slotSession != nil {
            // Mid-navigation settle window — hold the slot in the terminal
            // background colour so the eventual mount doesn't flash chrome.
            Color(nsColor: colorScheme == .dark
                ? GhosttyEmulator.darkBackground
                : GhosttyEmulator.lightBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Leading-edge/trailing-edge debounce for the mounted terminal. The
    /// first switch after a quiet period mounts immediately (no flash on a
    /// plain click or single keystroke); switches inside `rapidSwitchWindow`
    /// unmount the surface once and re-mount only after the burst settles,
    /// so cycling across N workspaces pays two surface reflows instead of 2N.
    private func syncDisplayedSession() {
        displaySettleTask?.cancel()
        let target = slot.hasBeenShown ? slotSession : nil
        guard target !== displayedSession else { return }

        let now = ContinuousClock.now
        let isRapid = lastSessionSwitch.map { now - $0 < Self.rapidSwitchWindow } ?? false
        lastSessionSwitch = now

        guard isRapid else {
            displayedSession = target
            return
        }
        displayedSession = nil
        displaySettleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            displayedSession = target
        }
    }
}

/// Terminal viewport for one session. Observes the session so transient state
/// (lastError, fellBackToShell) actually drives the UI.
private struct SessionSurface: View {
    @ObservedObject var session: PTYSession
    /// The tab is the visible one — only then does the terminal take focus
    /// and render.
    let isActive: Bool
    @EnvironmentObject private var state: AppState

    var body: some View {
        // The fallback banner sits above the terminal rather than over it:
        // over it, it hid the first row — all of a shell whose prompt only
        // ever redraws in place.
        VStack(spacing: 0) {
            if session.fellBackToShell {
                FallbackBanner(agent: session.agent)
            }
            ZStack(alignment: .top) {
                TerminalHostView(
                    session: session,
                    isActive: isActive,
                    paddingX: state.settings.terminalPaddingX
                )

                if let err = session.lastError {
                    ErrorOverlay(message: err)
                }
            }
        }
    }
}

private struct FallbackBanner: View {
    let agent: Workspace.AgentKind

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Couldn't find `\(agent.executableName)` on PATH — opened a login shell instead. Set the binary path in Settings → Agents.")
                .font(.caption)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct ErrorOverlay: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
            Text(message).multilineTextAlignment(.center)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding()
    }
}

/// Brand mark for an agent. Branded agents ship PNG assets in
/// `Sources/JetlineApp/Resources` (loaded via NSImage — SwiftUI's
/// `Image(_:bundle:)` only resolves asset-catalog entries). The plain
/// terminal has no logo and falls back to an SF Symbol.
struct AgentMark: View {
    let agent: Workspace.AgentKind
    var size: CGFloat = 16

    var body: some View {
        if let nsImage = Self.cache[agent] {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let symbol = symbolFallback {
            Image(systemName: symbol)
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }

    private var symbolFallback: String? {
        switch agent {
        case .shell: return "terminal"
        case .claude, .codex, .vibe: return nil
        }
    }

    /// The mark as an `NSImage`, for AppKit surfaces (the native tab title).
    static func image(for agent: Workspace.AgentKind) -> NSImage? {
        if let image = cache[agent] { return image }
        return agent == .shell
            ? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            : nil
    }

    private static let cache: [Workspace.AgentKind: NSImage] = {
        var map: [Workspace.AgentKind: NSImage] = [:]
        let assetNames: [Workspace.AgentKind: String] = [
            .claude: "ClaudeCodeMark",
            .codex: "CodexMark",
            .vibe: "MistralVibeMark"
        ]
        for (kind, name) in assetNames {
            if let url = Bundle.jetlineResources.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                map[kind] = img
            }
        }
        return map
    }()
}

/// SwiftUI ↔ NSView bridge that hosts whichever `TerminalEmulatorView` the
/// session was constructed with.
struct TerminalHostView: NSViewRepresentable {
    let session: PTYSession
    let isActive: Bool
    /// Inner horizontal padding, in points. Applied as a host-side surface
    /// inset (see `TerminalDropContainer`).
    var paddingX: Int = 0

    func makeNSView(context: Context) -> NSView {
        let container = TerminalDropContainer()
        container.session = session
        let term = session.emulator.nsView
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        let leading = term.leadingAnchor.constraint(
            equalTo: container.leadingAnchor, constant: CGFloat(paddingX)
        )
        let trailing = term.trailingAnchor.constraint(
            equalTo: container.trailingAnchor, constant: -CGFloat(paddingX)
        )
        container.leadingConstraint = leading
        container.trailingConstraint = trailing
        container.paddingX = CGFloat(paddingX)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leading,
            trailing
        ])
        session.emulator.setActive(isActive)
        if isActive {
            // SwiftUI's first updateNSView for a freshly-mounted representable
            // can fire before the container is attached to the window, so the
            // focus path there early-returns on `term.window == nil`. Schedule
            // the assertion here so a brand-new tab (e.g. one just spawned
            // from the + button or agent dropdown) lands focused and ready
            // for typing.
            DispatchQueue.main.async {
                guard let win = term.window, win.firstResponder !== term else { return }
                win.makeFirstResponder(term)
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.emulator.setActive(isActive)
        // Live-apply inner padding when the setting changes.
        (nsView as? TerminalDropContainer)?.paddingX = CGFloat(paddingX)
        // Focus is asserted on viewDidMoveToWindow when the tab swaps in. Don't
        // dispatch makeFirstResponder on every SwiftUI update — re-entering
        // layout during a NavigationSplitView divider drag is one of the paths
        // that crashes with `_postWindowNeedsUpdateConstraints`.
        let term = session.emulator.nsView
        guard isActive, let win = term.window, win.firstResponder !== term else { return }
        // Re-check at fire time: between dispatch and execution another tab
        // may have grabbed focus, the window may have closed, or the
        // emulator view may have been detached. Without these guards we'd
        // steal focus back from whatever the user is now interacting with.
        DispatchQueue.main.async {
            guard let win = term.window,
                  win.firstResponder !== term else { return }
            win.makeFirstResponder(term)
        }
    }

    /// SwiftUI is tearing this host down — typically because `.id(session.id)`
    /// swapped to a different tab. Park the emulator back in the offscreen
    /// incubator so it keeps a window: without this the term is orphaned,
    /// libghostty's surface tears down, and PTY chunks that arrive while the
    /// tab is hidden get dropped. The surface persists across the reparent
    /// so when the user comes back the conversation is intact.
    /// Only re-park while the terminal is still our subview: a closed
    /// session's view was already detached by `closeSession` /
    /// `tearDownWorkspaceRuntime` to release the libghostty surface, and
    /// parking it here would resurrect that strong reference for good.
    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        guard let container = nsView as? TerminalDropContainer,
              let session = container.session,
              session.emulator.nsView.superview === container else { return }
        TerminalIncubator.park(session.emulator.nsView)
        session.emulator.setActive(false)
    }
}

/// Terminal-area drop target. libghostty's `AppTerminalView` doesn't register
/// for any drag types, so dragging a file or image from Finder, a browser, or
/// a screenshot tool does nothing — agents like Claude Code that read paths
/// from their input never see the drop. This container sits underneath the
/// terminal view in the responder chain and translates drops into a paste
/// (so libghostty wraps the path in DECSET-2004 brackets when the host
/// program is in bracketed-paste mode — without that Claude treats the path
/// as typed text and just echoes it). Bare images (browser drags, screenshot
/// apps) are spilled to a temp PNG first so the agent has a file to read.
private final class TerminalDropContainer: NSView {
    weak var session: PTYSession?

    /// Leading/trailing constraints of the hosted terminal view. Their
    /// constants are the inner horizontal padding — kept here so a settings
    /// change can update them live. libghostty's `window-padding-x` is inert
    /// for embedded surfaces (padding is a host responsibility, exactly as
    /// ghostty's own app insets its surface view), so we apply it here and
    /// paint the exposed strips in the terminal background colour to read as
    /// padding *inside* the terminal rather than window chrome around it.
    var leadingConstraint: NSLayoutConstraint?
    var trailingConstraint: NSLayoutConstraint?

    var paddingX: CGFloat = 0 {
        didSet {
            guard paddingX != oldValue else { return }
            leadingConstraint?.constant = paddingX
            trailingConstraint?.constant = -paddingX
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.isDark
        layer?.backgroundColor =
            (isDark ? GhosttyEmulator.darkBackground : GhosttyEmulator.lightBackground).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptableOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptableOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = collectPaths(from: sender)
        guard !paths.isEmpty, let session else { return false }
        // The agent reads the file where it runs: with a remote engine the
        // drop goes up first and the pasted path is the engine's copy.
        Task { @MainActor in
            var enginePaths: [String] = []
            for path in paths {
                if let uploaded = try? await session.files.upload(URL(fileURLWithPath: path)) {
                    enginePaths.append(uploaded)
                }
            }
            guard !enginePaths.isEmpty else { return }
            session.emulator.paste(enginePaths.map(Self.shellEscape).joined(separator: " ") + " ")
        }
        return true
    }

    private func acceptableOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return .copy
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return .copy
        }
        return []
    }

    private func collectPaths(from sender: NSDraggingInfo) -> [String] {
        let pb = sender.draggingPasteboard
        // File URLs win when present — `kUTType.fileURL` covers Finder drags,
        // and most browsers/screenshot tools that promise a real file expose
        // it here too.
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        // Fall back to bare image payloads (e.g. dragging an <img> from
        // Safari, or pasting a screenshot from CleanShot). Persist to a temp
        // PNG so the agent has a path it can actually open.
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !images.isEmpty {
            return images.compactMap(Self.persistImage)
        }
        return []
    }

    private static func persistImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetline-drop-\(UUID().uuidString.prefix(8)).png")
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    /// POSIX single-quote shell escape: wrap in single quotes, replacing any
    /// embedded `'` with `'\''`. Works whether the receiving agent feeds the
    /// path into a shell or parses it directly — single-quoted whitespace and
    /// special characters round-trip cleanly in both.
    private static func shellEscape(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
#endif
