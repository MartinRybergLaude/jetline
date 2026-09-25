import SwiftUI

/// What the tab bar's `+` opens: a page for picking what the new tab
/// becomes — a chat or a terminal for one of the agents, or a closed chat
/// brought back. Picking one turns this tab into it, in place.
///
/// Laid out like a Settings pane: one grouped row per agent, with the ways
/// to open it as buttons on the trailing edge, so each agent appears once.
struct NewTabPage: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    let launcherId: String

    @State private var closedChats: [ChatThreadRecord] = []

    private var visibleAgents: [Workspace.AgentKind] {
        Workspace.AgentKind.allCases.filter(state.settings.isAgentVisible)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Tab")
                        .font(.title.weight(.semibold))
                    Text(workspace.name)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                group("Start") {
                    ForEach(Array(visibleAgents.enumerated()), id: \.element) { index, agent in
                        if index > 0 { GroupSeparator(inset: 50) }
                        AgentRow(
                            agent: agent,
                            canChat: AgentProviderKind(agent: agent) != nil,
                            defaultMode: defaultMode(for: agent),
                            openChat: {
                                guard let provider = AgentProviderKind(agent: agent) else { return }
                                state.startNewChat(for: workspace, provider: provider, replacing: .launcher(launcherId))
                            },
                            openTerminal: {
                                state.startNewTerminal(for: workspace, agent: agent, replacing: .launcher(launcherId))
                            }
                        )
                    }
                }

                if !closedChats.isEmpty {
                    group("Recently Closed") {
                        ForEach(Array(closedChats.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { GroupSeparator(inset: 40) }
                            ReopenRow(record: record) {
                                state.reopenChat(record, in: workspace, replacing: .launcher(launcherId))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 56)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            closedChats = ChatStore.closedThreads(workspaceId: workspace.id, limit: 8)
        }
    }

    /// The pick the toolbar used to start with one click: the default agent
    /// in the default interface. Return picks it.
    private func defaultMode(for agent: Workspace.AgentKind) -> AgentRow.Mode? {
        guard agent == state.settings.defaultAgent else { return nil }
        return state.settings.opensChat(for: agent) ? .chat : .terminal
    }


    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
            VStack(spacing: 0) {
                rows()
            }
            .padding(4)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.06))
            }
        }
    }
}

private struct GroupSeparator: View {
    let inset: CGFloat

    var body: some View {
        Divider().padding(.leading, inset).padding(.trailing, 10)
    }
}

/// An agent, and a capsule per way to open it. The default pick is the
/// prominent one.
private struct AgentRow: View {
    enum Mode { case chat, terminal }

    let agent: Workspace.AgentKind
    let canChat: Bool
    let defaultMode: Mode?
    let openChat: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AgentMark(agent: agent, size: 28)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if canChat {
                modeButton("Chat", systemImage: "bubble.left", mode: .chat, action: openChat)
            }
            modeButton("Terminal", systemImage: "terminal", mode: .terminal, action: openTerminal)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var subtitle: String {
        if agent == .shell { return "Your login shell" }
        return canChat ? "Chat or run in a terminal" : "Runs in a terminal"
    }

    @ViewBuilder
    private func modeButton(
        _ title: String,
        systemImage: String,
        mode: Mode,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .padding(.horizontal, 2)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        if defaultMode == mode {
            button
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

private struct ReopenRow: View {
    let record: ChatThreadRecord
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AgentMark(agent: record.provider.agentKind, size: 18)
                    .frame(width: 18, height: 18)
                Text(record.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(record.updatedAt, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.uturn.backward")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Reopen this chat")
    }
}
