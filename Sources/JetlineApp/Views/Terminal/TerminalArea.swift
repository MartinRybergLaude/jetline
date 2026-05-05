import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TerminalArea: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    /// Session id currently being dragged in the tab strip. Set by `.onDrag`,
    /// cleared on drop completion. The drop delegate keys reorders off this
    /// so external text drags can't accidentally reorder tabs.
    @State private var draggingTabId: String?

    var body: some View {
        VStack(spacing: 0) {
            sessionTabStrip
            terminalSurface
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(workspace.name)
        // Suppress the stock title rendering — our principal item below
        // takes its place. `navigationTitle` above still drives the window
        // menu proxy, Dock tooltip and accessibility label.
        .toolbar(removing: .title)
        .toolbar {
            // `.navigation` puts content at the leading edge of the detail
            // titlebar (right after the split separator), unlike `.principal`
            // which centres between two flex spaces. The explicit
            // `ToolbarSpacer` in between keeps the trailing actions anchored
            // to the right edge — without it they collapse next to the
            // title.
            ToolbarItem(placement: .navigation) {
                WorkspaceTitleBar(
                    name: workspace.name,
                    branch: workspace.branchName,
                    stats: state.diffByWorkspace[workspace.id]
                )
            }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) {
                runToolbarItems
            }
        }
    }

    @ViewBuilder
    private var runToolbarItems: some View {
        GitActionMenu(workspace: workspace)
        OpenInAppButton(workspace: workspace)
        RunToolbarSlot(workspace: workspace)
        Button {
            state.inspectorVisible.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .symbolVariant(state.inspectorVisible ? .fill : .none)
        }
        .help("Toggle inspector")
    }

    @ViewBuilder
    private var sessionTabStrip: some View {
        let sessions = state.sessionsByWorkspace[workspace.id] ?? []
        let activeId = state.activeSessionByWorkspace[workspace.id]
        let sessionIds = sessions.map(\.id)
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(sessions) { session in
                        BorderedTab(
                            session: session,
                            isActive: session.id == activeId,
                            onSelect: { state.selectSession(session.id, in: workspace.id) },
                            onClose: { state.closeSession(session.id, in: workspace.id) }
                        )
                        .id(session.id)
                        .onDrag {
                            draggingTabId = session.id
                            return NSItemProvider(object: session.id as NSString)
                        }
                        .onDrop(
                            of: [.text],
                            delegate: TabReorderDelegate(
                                targetId: session.id,
                                draggingTabId: $draggingTabId,
                                onReorder: { source, target in
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                        state.moveSession(source, before: target, in: workspace.id)
                                    }
                                }
                            )
                        )
                    }
                    NewSessionMenu(
                        defaultAgent: state.settings.defaultAgent,
                        visibleAgents: Workspace.AgentKind.allCases.filter(state.settings.isAgentVisible),
                        // Resolve the workspace at click time rather than capturing it.
                        // SwiftUI keeps NewSessionMenu's view identity stable across
                        // workspace switches, so the NSMenuItem actions inside the
                        // dropdown end up bound to the closure from first build —
                        // a captured `workspace` would route new tabs to whichever
                        // workspace was active when the menu was first realized.
                        // `primaryAction:` (the plus button) refreshes correctly,
                        // which is why only the dropdown shows the bug.
                        onStart: { agent in
                            guard let id = state.selectedWorkspaceId,
                                  let ws = state.workspaceById(id) else { return }
                            state.startNewSession(for: ws, agent: agent)
                        }
                    )
                    .id("new-session-menu")
                    Spacer(minLength: 0)
                }
                .padding(.leading, 6)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .onChange(of: activeId) { _, newId in
                guard let newId else { return }
                proxy.scrollTo(newId, anchor: .center)
            }
            .onChange(of: sessionIds) { oldIds, newIds in
                guard newIds.count > oldIds.count,
                      let added = newIds.first(where: { !oldIds.contains($0) }) else { return }
                proxy.scrollTo(added, anchor: .trailing)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let session = state.activeSession(for: workspace.id) {
            SessionSurface(session: session)
                .id(session.id)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Title-area content rendered into the window's principal toolbar slot.
/// Matches the system title styling — name in headline weight on top,
/// branch in secondary subheadline below — and adds a coloured diff pill
/// alongside the branch. The Liquid Glass capsule the toolbar would
/// normally wrap this in is stripped at the AppKit level by the embedded
/// `UnborderHost`, which finds its host `NSToolbarItem` and clears its
/// `isBordered` flag (the same flag that keeps the system title item
/// pill-free).
private struct WorkspaceTitleBar: View {
    let name: String
    let branch: String
    let stats: DiffSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 8) {
                Text(branch)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let stats, !stats.isEmpty {
                    ChangesPill(adds: stats.totalAdditions, dels: stats.totalDeletions)
                }
            }
        }
        .padding(.leading, 8)
        .background(UnborderHost().frame(width: 0, height: 0))
    }
}

/// Self-locating unborder. The probe NSView lives inside the SwiftUI tree
/// that's hosted by the principal `NSToolbarItem` — so once it's mounted in
/// a window, walking up its superview chain hits a `ToolbarItemHostingView`,
/// which is referenced by exactly one `NSToolbarItem`. We flip that item's
/// `isBordered` to `false`, which (per AppKit) suppresses the Liquid Glass
/// capsule. Position-based / identifier-based matching would be fragile —
/// SwiftUI assigns UUID identifiers and shuffles item order — so we let the
/// view tell us which item it lives in.
private struct UnborderHost: NSViewRepresentable {
    func makeNSView(context: Context) -> UnborderProbe { UnborderProbe() }
    func updateNSView(_ nsView: UnborderProbe, context: Context) {
        nsView.unborderHostItem()
    }
}

private final class UnborderProbe: NSView {
    /// Pending retry items. Held so a fresh `unborderHostItem()` (e.g. from
    /// SwiftUI's `updateNSView`) can cancel any still-queued attempts before
    /// scheduling its own — otherwise repeated layout passes pile up dozens
    /// of stale closures, each capturing self.
    private var pendingRetries: [DispatchWorkItem] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unborderHostItem()
    }

    /// Toolbar items mount asynchronously; retry across a few frames until
    /// our host view is wired into a `ToolbarItemHostingView` whose
    /// `NSToolbarItem` we can reach. Idempotent.
    func unborderHostItem() {
        for item in pendingRetries { item.cancel() }
        pendingRetries.removeAll(keepingCapacity: true)

        for delay: TimeInterval in [0.0, 0.05, 0.2, 0.6] {
            let item = DispatchWorkItem { [weak self] in
                self?.tryUnborder()
            }
            pendingRetries.append(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func tryUnborder() {
        guard let host = enclosingToolbarItemHost(),
              let toolbar = window?.toolbar else { return }
        for item in toolbar.items where item.view === host {
            if item.isBordered { item.isBordered = false }
            // Once we've found and unbordered the item, drop any still-queued
            // retries — they'd just repeat the same successful work.
            for r in pendingRetries { r.cancel() }
            pendingRetries.removeAll(keepingCapacity: true)
            return
        }
    }

    /// Walk superviews until we hit the AppKit-private `ToolbarItemHostingView`
    /// class that wraps SwiftUI content inside an `NSToolbarItem`.
    private func enclosingToolbarItemHost() -> NSView? {
        var current: NSView? = self
        while let v = current {
            if String(describing: type(of: v)).contains("ToolbarItemHostingView") {
                return v
            }
            current = v.superview
        }
        return nil
    }
}

private struct ChangesPill: View {
    let adds: Int
    let dels: Int

    var body: some View {
        HStack(spacing: 4) {
            if adds > 0 {
                Text("+\(adds)").foregroundStyle(.green)
            }
            if dels > 0 {
                Text("−\(dels)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
    }
}

/// Toolbar slot for the run/setup button. Two-stage routing so the spinner
/// flips to "Run" the moment setup exits: the outer view depends only on
/// `setupByWorkspace` membership (a published map), the inner view holds an
/// `@ObservedObject` SetupController and re-renders on its phase changes.
/// Without this split, the toolbar wouldn't know when setup finished — the
/// AppState dict still has the controller in it, so no published change.
private struct RunToolbarSlot: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        if let setup = state.setupController(for: workspace.id) {
            SetupAwareRunSlot(workspace: workspace, controller: setup)
        } else if state.hasRunScript(workspace) {
            ReadyOrRunningRunSlot(workspace: workspace)
        }
    }
}

private struct SetupAwareRunSlot: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    @ObservedObject var controller: SetupController

    var body: some View {
        if controller.isRunning {
            Button { /* disabled */ } label: {
                Label {
                    Text("Setting up")
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(true)
            .help("Setup is running. Run will be available once setup completes.")
        } else if state.hasRunScript(workspace) {
            ReadyOrRunningRunSlot(workspace: workspace)
        }
    }
}

private struct ReadyOrRunningRunSlot: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        if let runner = state.runController(for: workspace.id) {
            RunStatusButton(runner: runner) { state.toggleRun(for: workspace) }
        } else {
            Button {
                state.toggleRun(for: workspace)
            } label: {
                Label("Run", systemImage: "play.fill")
            }
            .help("Run the configured run script")
        }
    }
}

/// Toolbar button that mirrors the runner's phase: play icon when idle,
/// pulsing yellow dot while spinning up, solid green once it's settled.
/// Click toggles start/stop in any phase.
private struct RunStatusButton: View {
    @ObservedObject var runner: RunController
    let onToggle: () -> Void
    @State private var pulse: Bool = false

    var body: some View {
        Button(action: onToggle) {
            label
        }
        .help(helpText)
    }

    @ViewBuilder
    private var label: some View {
        Label {
            Text(accessibilityTitle)
        } icon: {
            Image(systemName: runner.phase == .idle ? "play.fill" : "stop.fill")
                .overlay(alignment: .topTrailing) { statusDot }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch runner.phase {
        case .idle:
            EmptyView()
        case .starting:
            Circle()
                .fill(.yellow)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 0.35 : 1.0)
                .animation(
                    .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                    value: pulse
                )
                .onAppear { pulse = true }
                .onDisappear { pulse = false }
                .offset(x: 3, y: -3)
        case .running:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .offset(x: 3, y: -3)
        }
    }

    private var accessibilityTitle: String {
        switch runner.phase {
        case .idle: return "Run"
        case .starting: return "Starting"
        case .running: return "Running"
        }
    }

    private var helpText: String {
        switch runner.phase {
        case .idle: return "Run the configured run script"
        case .starting: return "Starting… click to stop"
        case .running: return "Running — click to stop"
        }
    }
}

/// Terminal viewport for one session. Observes the session so transient state
/// (lastError, fellBackToShell) actually drives the UI.
private struct SessionSurface: View {
    @ObservedObject var session: PTYSession

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHostView(session: session, isActive: true)

            if session.fellBackToShell {
                FallbackBanner(agent: session.agent)
            }

            if let err = session.lastError {
                ErrorOverlay(message: err)
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

/// Tab styled after Apple HIG: the active tab is lifted out of the recessed
/// strip with the system text background, an accent indicator across the top
/// edge, and bolder text. Inactive tabs gain a soft hover tint and show a
/// hairline separator only between adjacent inactive siblings — same trick
/// Safari uses to keep the strip from looking like a row of buttons.
private struct BorderedTab: View {
    @ObservedObject var session: PTYSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var closeHovering = false

    var body: some View {
        HStack(spacing: 7) {
            AgentMark(agent: session.agent, size: 14)
                .opacity(isActive ? 1 : 0.75)
            Text(session.agent.displayName)
                .lineLimit(1)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? .primary : .secondary)
            closeButton
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(minWidth: 110)
        .background(tabBackground)
        .overlay(alignment: .top) { activeAccent }
        .overlay(alignment: .trailing) { trailingSeparator }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var closeButton: some View {
        // Always laid out so tab width is stable; revealed on tab hover.
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(closeHovering ? .primary : .secondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(closeHovering ? 0.16 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovering || closeHovering ? 1 : 0)
        .onHover { closeHovering = $0 }
        .help("Close tab")
    }

    @ViewBuilder
    private var tabBackground: some View {
        if isActive {
            Color(nsColor: .textBackgroundColor)
        } else if hovering {
            Color.primary.opacity(0.06)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var activeAccent: some View {
        if isActive {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 1.5)
        }
    }

    @ViewBuilder
    private var trailingSeparator: some View {
        if !isActive {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(width: 1, height: 16)
                .padding(.vertical, 8)
        }
    }
}

/// Drop delegate for reordering tabs by drag. Lives between the active
/// drag (whose source id is parked in `draggingTabId`) and the tab being
/// hovered. Reorder fires on `dropEntered` so the strip slides under the
/// cursor live; `validateDrop` rejects anything not started by a tab drag
/// so plain-text drops from other apps don't shuffle the strip.
private struct TabReorderDelegate: DropDelegate {
    let targetId: String
    @Binding var draggingTabId: String?
    let onReorder: (_ source: String, _ target: String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingTabId != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let source = draggingTabId, source != targetId else { return }
        onReorder(source, targetId)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingTabId = nil
        return true
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

    private static let cache: [Workspace.AgentKind: NSImage] = {
        var map: [Workspace.AgentKind: NSImage] = [:]
        let assetNames: [Workspace.AgentKind: String] = [
            .claude: "ClaudeCodeMark",
            .codex: "CodexMark",
            .vibe: "MistralVibeMark"
        ]
        for (kind, name) in assetNames {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                map[kind] = img
            }
        }
        return map
    }()
}

/// Split menu button: the icon click starts a session with the user's default
/// agent; the chevron exposes the other agents.
private struct NewSessionMenu: View {
    let defaultAgent: Workspace.AgentKind
    let visibleAgents: [Workspace.AgentKind]
    let onStart: (Workspace.AgentKind) -> Void

    var body: some View {
        Menu {
            ForEach(visibleAgents, id: \.self) { kind in
                Button {
                    onStart(kind)
                } label: {
                    Text("New \(kind.displayName) tab")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.callout)
                .padding(10)
        } primaryAction: {
            onStart(defaultAgent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("New \(defaultAgent.displayName) tab")
    }
}

/// Split-action toolbar button: clicking the body opens the workspace's
/// worktree in the user's last-chosen app; the chevron exposes the picker,
/// and picking an app both updates the default and opens the folder.
private struct OpenInAppButton: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    /// Falls back to Finder if the persisted choice was uninstalled since
    /// it was saved — Finder is always present.
    private var current: OpenInApp {
        let stored = state.settings.defaultOpenInApp
        return stored.isInstalled ? stored : .finder
    }

    var body: some View {
        Menu {
            ForEach(OpenInApp.allCases.filter(\.isInstalled), id: \.self) { app in
                Button {
                    var s = state.settings
                    s.defaultOpenInApp = app
                    state.saveSettings(s)
                    app.open(directory: workspace.worktreePath)
                } label: {
                    if let icon = app.icon(size: 16) {
                        Label {
                            Text(app.displayName)
                        } icon: {
                            Image(nsImage: icon)
                        }
                    } else {
                        Text(app.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let icon = current.icon(size: 14) {
                    Image(nsImage: icon)
                        .frame(width: 14, height: 14)
                }
                Text(current.displayName)
            }
        } primaryAction: {
            current.open(directory: workspace.worktreePath)
        }
        .menuIndicator(.visible)
        .help("Open workspace in \(current.displayName)")
    }
}

/// SwiftUI ↔ NSView bridge that hosts whichever `TerminalEmulatorView` the
/// session was constructed with.
struct TerminalHostView: NSViewRepresentable {
    let session: PTYSession
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = TerminalDropContainer()
        container.session = session
        let term = session.emulator.nsView
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptableOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptableOperation(for: sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = collectPaths(from: sender)
        guard !paths.isEmpty, let session else { return false }
        let text = paths.map(Self.shellEscape).joined(separator: " ") + " "
        session.emulator.paste(text)
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
