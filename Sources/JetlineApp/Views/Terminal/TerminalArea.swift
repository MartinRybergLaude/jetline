import SwiftUI
import AppKit

struct TerminalArea: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            sessionTabStrip
            terminalSurface
                .padding(.leading, 8)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(workspace.name)
        .navigationSubtitle(workspace.branchName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                runToolbarItems
            }
        }
    }

    @ViewBuilder
    private var runToolbarItems: some View {
        if let stats = state.diffByWorkspace[workspace.id], !stats.files.isEmpty {
            ChangesPill(adds: stats.totalAdditions, dels: stats.totalDeletions)
        }
        OpenInAppButton(workspace: workspace)
        if state.hasRunScript(workspace) {
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sessions) { session in
                    BorderedTab(
                        session: session,
                        isActive: session.id == activeId,
                        onSelect: { state.selectSession(session.id, in: workspace.id) },
                        onClose: { state.closeSession(session.id, in: workspace.id) }
                    )
                }
                NewSessionMenu(
                    defaultAgent: state.settings.defaultAgent,
                    visibleAgents: Workspace.AgentKind.allCases.filter(state.settings.isAgentVisible),
                    onStart: { state.startNewSession(for: workspace, agent: $0) }
                )
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
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

private struct ChangesPill: View {
    let adds: Int
    let dels: Int

    var body: some View {
        HStack(spacing: 4) {
            if adds > 0 {
                Text("+\(adds)").foregroundStyle(.green)
            }
            if dels > 0 {
                Text("-\(dels)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .opacity(0.85)
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

/// Flat bordered tab. Active tab uses the system text background to read as
/// "in front"; inactive tabs sit on a slightly recessed fill. Right-edge
/// border on every tab gives the dividing line the user wants.
private struct BorderedTab: View {
    @ObservedObject var session: PTYSession
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            AgentMark(agent: session.agent, size: 14)
                .opacity(isActive ? 1 : 0.7)
            Text(session.agent.displayName)
                .lineLimit(1)
                .foregroundStyle(isActive ? .primary : .secondary)
            // Always laid out (so tab width is stable); revealed on hover.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Close tab")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isActive ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
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
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
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
        let container = NSView()
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
        DispatchQueue.main.async { win.makeFirstResponder(term) }
    }
}
