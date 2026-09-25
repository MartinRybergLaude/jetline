import SwiftUI

/// Main-area content of a chat tab.
struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.tabSlot) private var slot
    let session: ChatSession
    @State private var popup = ComposerPopup()

    var body: some View {
        VStack(spacing: 0) {
            ChatTimelineView(session: session)
                .overlay(alignment: .topTrailing) { floatingActions }
                // Here rather than on the composer: the timeline is an
                // AppKit view, which draws over any SwiftUI content that
                // spills onto it from below.
                .overlay(alignment: .bottom) {
                    if !popup.items.isEmpty {
                        ComposerSuggestionList(popup: popup)
                            .frame(maxWidth: 720, alignment: .leading)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                            .frame(maxWidth: .infinity)
                    }
                }
            VStack(spacing: 0) {
                Divider()
                bottom
                    .frame(maxWidth: 720)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { slot?.composerBarHeight = $0 }
        }
        .background(Color(nsColor: .textBackgroundColor))
        // A fixed floor, independent of content. Otherwise the detail
        // column's minimum is derived from whatever the lazy timeline and
        // composer currently lay out, which shifts as a divider drag
        // squeezes them; NSSplitView then re-runs constraints every pass
        // and AppKit aborts with `_postWindowNeedsUpdateConstraints`.
        .frame(minWidth: 320, maxWidth: .infinity)
        .clipped()
        .environment(\.chatFontFamily, state.settings.chatFontFamily)
        .onAppear { session.connectIfNeeded() }
        .onDisappear { slot?.composerBarHeight = nil }
    }

    // MARK: Floating actions

    private var floatingActions: some View {
        HStack(spacing: 8) {
            ConnectionBadge(connection: session.connection)
            if session.terminalResumeArgs != nil {
                Button {
                    state.openChatInTerminal(session)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .disabled(session.isWorking)
                .help("Continue this conversation in \(session.provider.displayName)'s own terminal UI")
            }
        }
        .padding(12)
    }

    // MARK: Bottom

    @ViewBuilder
    private var bottom: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case let .failed(message) = session.connection {
                BannerView(text: message, level: .error) {
                    Button("Retry") { session.connectIfNeeded() }
                }
            }
            if let banner = session.banner {
                BannerView(text: banner, level: .warning) {
                    Button("Dismiss") { session.banner = nil }
                }
            }
            if !session.todos.isEmpty {
                TodoStrip(todos: session.todos)
            }
            if let request = session.requests.first {
                ChatRequestPanel(session: session, request: request)
            } else {
                ChatComposer(session: session, popup: popup)
                    .disabled(session.isReverting)
            }
        }
    }
}

private struct ConnectionBadge: View {
    let connection: ChatSession.Connection

    var body: some View {
        switch connection {
        case .connecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Starting…")
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 13))
        case .connected, .disconnected:
            EmptyView()
        }
    }
}

private struct BannerView<Actions: View>: View {
    let text: String
    let level: AgentItem.Notice.Level
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(level == .error ? Color.red : Color.orange)
            Text(text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions.controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The agent's working checklist, pinned above the composer.
private struct TodoStrip: View {
    let todos: [AgentTodo]
    @State private var expanded = false

    var body: some View {
        let done = todos.filter { $0.status == .completed }.count
        let current = todos.first { $0.status == .inProgress }
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                    Text("\(done)/\(todos.count)")
                        .monoFont(size: 13, weight: .semibold)
                    Text(current?.text ?? (done == todos.count ? "All steps done" : "Plan"))
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up")
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .font(.system(size: 11))
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { _, todo in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: icon(todo.status))
                                .foregroundStyle(todo.status == .completed ? Color.readableGreen : .secondary)
                                .font(.system(size: 13))
                            Text(todo.text)
                                .strikethrough(todo.status == .completed)
                                .foregroundStyle(todo.status == .completed ? .secondary : .primary)
                        }
                        .font(.system(size: 14))
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(_ status: AgentTodo.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted.circle"
        case .completed: return "checkmark.circle.fill"
        }
    }
}
