import SwiftUI
import AppKit

struct TerminalArea: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            TerminalHeader(workspace: workspace)
            Divider()
            sessionTabs
            Divider().opacity(0.5)
            terminalSurface
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private var sessionTabs: some View {
        let sessions = state.sessionsByWorkspace[workspace.id] ?? []
        let active = state.activeSessionByWorkspace[workspace.id]
        let defaultAgent = state.settings.defaultAgent
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isActive: session.id == active,
                        onSelect: { state.selectSession(session.id, in: workspace.id) }
                    )
                }
                NewSessionMenu(
                    defaultAgent: defaultAgent,
                    onStart: { state.startNewSession(for: workspace, agent: $0) }
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var terminalSurface: some View {
        if let session = state.activeSession(for: workspace.id) {
            // SessionSurface observes the session so banners/errors update live.
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

private struct TerminalHeader: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            Text(workspace.name).font(.headline)
            Text(workspace.branchName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            if let session = state.activeSession(for: workspace.id) {
                Button {
                    session.interrupt()
                } label: {
                    Label("Interrupt", systemImage: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Send ^C to the session")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
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
                    Label("New \(kind.displayName) tab", systemImage: icon(for: kind))
                }
            }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            onStart(defaultAgent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("New \(defaultAgent.displayName) tab")
    }

    private func icon(for kind: Workspace.AgentKind) -> String {
        kind == .claude ? "sparkles" : "terminal"
    }
}

private struct SessionTab: View {
    @ObservedObject var session: PTYSession
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: session.agent == .claude ? "sparkles" : "terminal")
                Text(session.agent.displayName)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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
