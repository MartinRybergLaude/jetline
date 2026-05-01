import SwiftUI
import AppKit

struct TerminalArea: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            sessionTabStrip
            terminalSurface
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(workspace.name)
        .navigationSubtitle(workspace.branchName)
        .toolbar {
            if let session = state.activeSession(for: workspace.id) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        session.interrupt()
                    } label: {
                        Label("Interrupt", systemImage: "stop.circle")
                    }
                    .help("Send ^C to the session")
                }
            }
        }
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
                    onStart: { state.startNewSession(for: workspace, agent: $0) }
                )
                Spacer(minLength: 0)
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

/// Terminal viewport for one session. Observes the session so transient state
/// (lastError, fellBackToShell) actually drives the UI.
private struct SessionSurface: View {
    @ObservedObject var session: PTYSession

    var body: some View {
        ZStack(alignment: .top) {
            TerminalHostView(session: session)

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
/// `Sources/JetforgeApp/Resources` (loaded via NSImage — SwiftUI's
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
        case .claude, .codex: return nil
        }
    }

    private static let cache: [Workspace.AgentKind: NSImage] = {
        var map: [Workspace.AgentKind: NSImage] = [:]
        let assetNames: [Workspace.AgentKind: String] = [
            .claude: "ClaudeCodeMark",
            .codex: "CodexMark"
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
    let onStart: (Workspace.AgentKind) -> Void

    var body: some View {
        Menu {
            ForEach(Workspace.AgentKind.allCases, id: \.self) { kind in
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

/// SwiftUI ↔ NSView bridge that hosts whichever `TerminalEmulatorView` the
/// session was constructed with.
struct TerminalHostView: NSViewRepresentable {
    let session: PTYSession

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
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-assert focus when the active tab swaps in.
        DispatchQueue.main.async {
            session.emulator.nsView.window?.makeFirstResponder(session.emulator.nsView)
        }
    }
}
