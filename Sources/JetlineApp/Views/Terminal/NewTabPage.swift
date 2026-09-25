import SwiftUI

/// What the tab bar's `+` opens: a page for picking what the new tab
/// becomes — a chat or a terminal for one of the agents, or a closed chat
/// brought back. Picking one turns this tab into it, in place.
struct NewTabPage: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    let launcherId: String

    @State private var closedChats: [ChatThreadRecord] = []

    private var visibleAgents: [Workspace.AgentKind] {
        Workspace.AgentKind.allCases.filter(state.settings.isAgentVisible)
    }

    private var chatAgents: [AgentProviderKind] {
        visibleAgents.compactMap(AgentProviderKind.init(agent:))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("New Tab")
                    .font(.largeTitle.weight(.semibold))

                if !chatAgents.isEmpty {
                    section("Chat") {
                        ForEach(chatAgents, id: \.self) { provider in
                            card(
                                agent: provider.agentKind,
                                title: provider.agentKind.displayName,
                                subtitle: "Chat",
                                isDefault: isDefault(provider.agentKind, chat: true)
                            ) {
                                _ = state.startNewChat(for: workspace, provider: provider)
                            }
                        }
                    }
                }

                section("Terminal") {
                    ForEach(visibleAgents, id: \.self) { agent in
                        card(
                            agent: agent,
                            title: agent.displayName,
                            subtitle: agent == .shell ? "Login shell" : "Terminal",
                            isDefault: isDefault(agent, chat: false)
                        ) {
                            state.startNewTerminal(for: workspace, agent: agent)
                        }
                    }
                }

                if !closedChats.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Reopen Chat")
                        VStack(spacing: 0) {
                            ForEach(closedChats, id: \.id) { record in
                                ReopenRow(record: record) {
                                    fill { state.reopenChat(record, in: workspace) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            closedChats = ChatStore.closedThreads(workspaceId: workspace.id, limit: 8)
        }
    }

    /// The pick the toolbar used to start with one click: the default agent
    /// in the default interface. Return picks it.
    private func isDefault(_ agent: Workspace.AgentKind, chat: Bool) -> Bool {
        agent == state.settings.defaultAgent && state.settings.opensChat(for: agent) == chat
    }

    private func fill(_ open: () -> Void) {
        state.fillLauncherTab(launcherId, in: workspace.id, with: open)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private func section(_ title: String, @ViewBuilder cards: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(title)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)], spacing: 12) {
                cards()
            }
        }
    }

    private func card(
        agent: Workspace.AgentKind,
        title: String,
        subtitle: String,
        isDefault: Bool,
        open: @escaping () -> Void
    ) -> some View {
        Button {
            fill(open)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                AgentMark(agent: agent, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(NewTabCardStyle(isDefault: isDefault))
        .keyboardShortcut(isDefault ? .defaultAction : nil)
    }
}

/// A Liquid Glass card that lifts under the pointer.
private struct NewTabCardStyle: ButtonStyle {
    let isDefault: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .glassEffect(
                .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .overlay {
                if isDefault {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct ReopenRow: View {
    let record: ChatThreadRecord
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AgentMark(agent: record.provider.agentKind, size: 16)
                Text(record.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                Text(record.updatedAt, format: .relative(presentation: .named))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
