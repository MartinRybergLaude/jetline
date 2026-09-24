import SwiftUI

/// The scrolling conversation. Follows new output while the user is at the
/// bottom; scrolling up to read stops the follow until they return.
struct ChatTimelineView: View {
    let session: ChatSession
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: ChatTurnView.turnSpacing) {
                if session.turns.isEmpty {
                    ChatEmptyState(provider: session.provider)
                }
                ForEach(session.turns) { turn in
                    ChatTurnView(session: session, turn: turn)
                        .id(turn.id)
                }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.top, 52)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity)
        }
        .environment(\.markdownTableBreakoutWidth, max(width - 48, 0))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height
        } action: { old, new in
            guard new > old, isAtBottom else { return }
            position.scrollTo(edge: .bottom)
        }
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                .padding(16)
                .help("Scroll to bottom")
            }
        }
    }
}

private struct ChatEmptyState: View {
    let provider: AgentProviderKind

    var body: some View {
        VStack(spacing: 10) {
            AgentMark(agent: provider.agentKind, size: 36)
            Text("Chat with \(provider.displayName)")
                .font(.title3.weight(.semibold))
            Text("Ask for a change, a review or an explanation. Type / for commands and @ to mention files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }
}

struct ChatTurnView: View {
    let session: ChatSession
    let turn: ChatTurn

    static let turnSpacing: CGFloat = 40
    static let itemSpacing: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Self.itemSpacing) {
            let segments = ChatSegment.segments(turn.items)
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                switch segment {
                case let .user(box):
                    UserMessageView(
                        box: box,
                        timestamp: box.createdAt ?? turn.startedAt,
                        canRevert: session.canRevert && turn.status != .running && !session.isReverting,
                        onRevert: { session.revert(to: turn) }
                    )
                    // Same space below as the turn gap above it.
                    .padding(.bottom, Self.turnSpacing - Self.itemSpacing)
                case let .message(box):
                    AssistantMessageView(box: box, timestamp: box.createdAt ?? turn.completedAt)
                case let .work(boxes):
                    WorkGroupView(
                        boxes: boxes,
                        isLive: turn.status == .running && index == segments.count - 1,
                        cwd: session.cwd
                    )
                case let .plan(box):
                    PlanCardView(box: box)
                case let .notice(box):
                    NoticeView(box: box)
                case .compaction:
                    CompactionView()
                }
            }
            TurnFooter(session: session, turn: turn)
        }
    }
}

/// Below each turn: a live indicator while it runs, then what it changed
/// or how it ended.
private struct TurnFooter: View {
    let session: ChatSession
    let turn: ChatTurn

    var body: some View {
        switch turn.status {
        case .running:
            let waiting = !session.requests.isEmpty
            if (turn.providerTurnId != nil || !turn.items.isEmpty) && (waiting || !isWorkRunning) {
                WorkingIndicator(since: turn.startedAt, waiting: waiting)
            }
        case .completed:
            if let stat = turn.stat, !stat.isEmpty, let before = turn.checkpointBefore, let after = turn.checkpointAfter {
                ChangedFilesCard(cwd: session.cwd, stat: stat, from: before, to: after)
            }
        case .interrupted:
            Label("Interrupted", systemImage: "stop.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        case .failed:
            Label(turn.errorMessage ?? "The turn failed.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    /// A tool call or reasoning block is in progress; the work group shows
    /// its own progress then, so the footer indicator would double it.
    private var isWorkRunning: Bool {
        turn.items.contains { box in
            (box.kind == .work || box.kind == .reasoning) && box.item.status == .inProgress
        }
    }
}

private struct WorkingIndicator: View {
    let since: Date
    let waiting: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if waiting {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Waiting for you")
                } else {
                    ProgressView().controlSize(.small)
                    Text("Working · \(Self.format(context.date.timeIntervalSince(since)))")
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// What a turn changed on disk, from its checkpoints. Expands to the
/// per-file diffs, loaded on demand.
private struct ChangedFilesCard: View {
    let cwd: String
    let stat: Checkpointer.Stat
    let from: String
    let to: String
    @State private var expanded = false
    @State private var files: [FileDiff]?
    @State private var openFile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                    Text(stat.files == 1 ? "1 file changed" : "\(stat.files) files changed")
                    HStack(spacing: 3) {
                        Text("+\(stat.additions)").foregroundStyle(Color.readableGreen)
                        Text("−\(stat.deletions)").foregroundStyle(.red)
                    }
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Spacer()
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                        .font(.system(size: 12))
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                if let files {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(files) { file in
                            fileRow(file)
                        }
                    }
                } else {
                    ProgressView().controlSize(.small).padding(10)
                }
            }
        }
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
        .task(id: expanded) {
            guard expanded, files == nil else { return }
            files = await Checkpointer.diff(worktree: cwd, from: from, to: to)
        }
    }

    @ViewBuilder
    private func fileRow(_ file: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                openFile = openFile == file.path ? nil : file.path
            } label: {
                HStack(spacing: 8) {
                    FileStatusBadge(status: file.status)
                    Text(file.path).font(.system(size: 14)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    HStack(spacing: 3) {
                        if file.additions > 0 { Text("+\(file.additions)").foregroundStyle(Color.readableGreen) }
                        if file.deletions > 0 { Text("−\(file.deletions)").foregroundStyle(.red) }
                    }
                    .font(.system(size: 13, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if openFile == file.path {
                if file.isBinary {
                    Text("Binary file").font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 10)
                } else {
                    InlineDiffView(diff: file.hunks.map { hunk in
                        ([hunk.header] + hunk.lines.map { line in
                            switch line.kind {
                            case .addition: return "+" + line.text
                            case .deletion: return "-" + line.text
                            case .context: return " " + line.text
                            }
                        }).joined(separator: "\n")
                    }.joined(separator: "\n"))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }
        }
    }
}
