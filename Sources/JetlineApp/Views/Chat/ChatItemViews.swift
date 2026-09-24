import SwiftUI
import AppKit

/// A run of timeline rows rendered as one unit.
enum ChatSegment: Identifiable {
    case user(ChatItemBox)
    case message(ChatItemBox)
    /// Consecutive tool calls and reasoning, collapsed into one group.
    case work([ChatItemBox])
    case plan(ChatItemBox)
    case notice(ChatItemBox)
    case compaction(ChatItemBox)

    var id: String {
        switch self {
        case let .user(box), let .message(box), let .plan(box), let .notice(box), let .compaction(box):
            return box.id
        case let .work(boxes):
            return "work-" + (boxes.first?.id ?? "")
        }
    }

    /// Group a turn's items. Reads only `ChatItemBox.kind`, which never
    /// changes, so calling this from a view doesn't subscribe it to item
    /// content.
    @MainActor
    static func segments(_ boxes: [ChatItemBox]) -> [ChatSegment] {
        var segments: [ChatSegment] = []
        var work: [ChatItemBox] = []
        func flushWork() {
            if !work.isEmpty { segments.append(.work(work)) }
            work.removeAll()
        }
        for box in boxes {
            switch box.kind {
            case .work, .reasoning:
                work.append(box)
            case .user:
                flushWork()
                segments.append(.user(box))
            case .message:
                flushWork()
                segments.append(.message(box))
            case .plan:
                flushWork()
                segments.append(.plan(box))
            case .notice:
                flushWork()
                segments.append(.notice(box))
            case .compaction:
                flushWork()
                segments.append(.compaction(box))
            }
        }
        flushWork()
        return segments
    }
}

extension MarkdownStyle {
    /// Chat body text: larger than the inspector's comment style.
    static let chat = MarkdownStyle(bodySize: 14, codeSize: 13, blockSpacing: 10)
}

// MARK: - Messages

struct UserMessageView: View {
    let box: ChatItemBox
    let canRevert: Bool
    let onRevert: () -> Void
    @State private var hovering = false
    @State private var confirmingRevert = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Spacer(minLength: 60)
            if canRevert {
                Button {
                    confirmingRevert = true
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .help("Revert to before this message")
                .confirmationDialog("Revert to before this message?", isPresented: $confirmingRevert) {
                    Button("Revert", role: .destructive, action: onRevert)
                } message: {
                    Text("Files are restored to how they were before this message — including changes other tabs made since — and the agent forgets this message and everything after it. The message goes back into the composer.")
                }
            }
            if case let .userMessage(message) = box.item.content {
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.images.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(message.images, id: \.self) { path in
                                AttachmentThumbnail(url: URL(fileURLWithPath: path), size: 64)
                            }
                        }
                    }
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 14))
                            .textSelection(.enabled)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .onHover { hovering = $0 }
    }
}

struct AssistantMessageView: View {
    let box: ChatItemBox

    var body: some View {
        if case let .assistantMessage(text) = box.item.content, !text.isEmpty {
            StreamingMarkdown(text: text)
        }
    }
}

/// Markdown that re-parses as text streams in. Parsing is linear and
/// deltas are batched upstream (see `ChatSession.flushDeltas`), and this
/// view only re-renders when its own item's text changes.
private struct StreamingMarkdown: View {
    let text: String

    var body: some View {
        MarkdownView(blocks: MarkdownParser.parse(text), style: .chat)
            .textSelection(.enabled)
    }
}

// MARK: - Work group

/// Tool calls and reasoning of one stretch of a turn. Expanded while the
/// turn runs so progress is visible; collapsed to a one-line summary once
/// it's done.
struct WorkGroupView: View {
    let boxes: [ChatItemBox]
    let isLive: Bool
    let cwd: String
    @State private var expanded: Bool?

    private var isExpanded: Bool { expanded ?? isLive }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded = !isExpanded }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    WorkGroupSummary(boxes: boxes)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(boxes) { box in
                        WorkRowView(box: box, cwd: cwd)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

/// "3 commands, 2 edits, thinking" — counts by kind. Reads each item's
/// content, so it re-renders on streaming; it's one short line.
private struct WorkGroupSummary: View {
    let boxes: [ChatItemBox]

    var body: some View {
        Text(summary)
            .lineLimit(1)
    }

    private var summary: String {
        var commands = 0, edits = 0, reads = 0, tools = 0, searches = 0, agents = 0, thoughts = 0
        var running = false
        for box in boxes {
            if box.item.status == .inProgress { running = true }
            switch box.item.content {
            case .command: commands += 1
            case let .fileChange(change): edits += max(change.edits.count, 1)
            case let .tool(tool): if tool.summary?.hasPrefix("Read") == true { reads += 1 } else { tools += 1 }
            case .webSearch: searches += 1
            case .subagent: agents += 1
            case .reasoning: thoughts += 1
            default: break
            }
        }
        var parts: [String] = []
        func add(_ n: Int, _ one: String, _ many: String) {
            if n > 0 { parts.append(n == 1 ? "1 \(one)" : "\(n) \(many)") }
        }
        add(commands, "command", "commands")
        add(edits, "edit", "edits")
        add(reads, "file read", "files read")
        add(searches, "web search", "web searches")
        add(agents, "subagent", "subagents")
        add(tools, "tool call", "tool calls")
        if parts.isEmpty && thoughts > 0 { parts.append("Thought") }
        let text = parts.joined(separator: ", ")
        return running ? "Working… \(text)" : text
    }
}

struct WorkRowView: View {
    let box: ChatItemBox
    let cwd: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    StatusGlyph(status: box.item.status, symbol: symbol)
                        .frame(width: 14)
                    title
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasDetail)
            .padding(.leading, box.item.parentId == nil ? 0 : 16)

            if expanded && hasDetail {
                detail
                    .padding(.leading, box.item.parentId == nil ? 21 : 37)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch box.item.content {
        case .command: return "terminal"
        case .fileChange: return "pencil"
        case let .tool(tool): return tool.server == nil ? "wrench.and.screwdriver" : "puzzlepiece.extension"
        case .webSearch: return "globe"
        case .subagent: return "person.2"
        case .reasoning: return "brain"
        default: return "circle"
        }
    }

    @ViewBuilder
    private var title: some View {
        switch box.item.content {
        case let .command(command):
            HStack(spacing: 6) {
                Text(command.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command.command)
                    .font(.system(size: 13, design: .monospaced))
                if let code = command.exitCode, code != 0 {
                    Text("exit \(code)").foregroundStyle(.red).font(.system(size: 12))
                }
            }
        case let .fileChange(change):
            HStack(spacing: 6) {
                Text(change.edits.map { relative($0.path) }.joined(separator: ", ").nonBlank ?? "Edit")
                ForEach(Array(change.edits.prefix(1).enumerated()), id: \.offset) { _, edit in
                    DiffCounts(diff: edit.diff)
                }
            }
        case let .tool(tool):
            Text(tool.summary ?? [tool.server, tool.name].compactMap { $0 }.joined(separator: " · "))
        case let .webSearch(query):
            Text("Searched “\(query)”")
        case let .subagent(agent):
            Text([agent.agentType, agent.description].compactMap { $0 }.joined(separator: ": "))
        case let .reasoning(text):
            Text(text.isEmpty ? "Thinking…" : Self.firstLine(text))
                .foregroundStyle(.secondary)
                .italic()
        default:
            EmptyView()
        }
    }

    private var hasDetail: Bool {
        switch box.item.content {
        case let .command(command): return !command.output.isEmpty || command.command.contains("\n")
        case let .fileChange(change): return change.edits.contains { $0.diff?.isEmpty == false }
        case let .tool(tool): return tool.input?.object?.isEmpty == false || tool.output?.isEmpty == false
        case let .subagent(agent): return agent.prompt != nil || agent.result != nil
        case let .reasoning(text): return !text.isEmpty
        default: return false
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch box.item.content {
        case let .command(command):
            VStack(alignment: .leading, spacing: 4) {
                if command.command.contains("\n") {
                    MonospaceBlock(text: command.command)
                }
                if !command.output.isEmpty {
                    MonospaceBlock(text: command.output, maxLines: 40)
                }
            }
        case let .fileChange(change):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(change.edits.enumerated()), id: \.offset) { _, edit in
                    if let diff = edit.diff, !diff.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            if change.edits.count > 1 {
                                Text(relative(edit.path)).font(.system(size: 12, weight: .medium))
                            }
                            InlineDiffView(diff: diff)
                        }
                    }
                }
            }
        case let .tool(tool):
            VStack(alignment: .leading, spacing: 4) {
                if let input = tool.input, input.object?.isEmpty == false {
                    MonospaceBlock(text: input.prettyPrinted(), maxLines: 20)
                }
                if let output = tool.output, !output.isEmpty {
                    MonospaceBlock(text: output, maxLines: 30)
                }
            }
        case let .subagent(agent):
            VStack(alignment: .leading, spacing: 6) {
                if let prompt = agent.prompt {
                    Text(prompt).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let result = agent.result, !result.isEmpty {
                    MarkdownView(blocks: MarkdownParser.parse(result), style: .comment)
                }
            }
        case let .reasoning(text):
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }

    private func relative(_ path: String) -> String {
        path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.replacingOccurrences(of: "**", with: "")
    }
}

private struct StatusGlyph: View {
    let status: AgentItem.Status
    let symbol: String

    var body: some View {
        switch status {
        case .inProgress:
            ProgressView().controlSize(.mini)
        case .completed:
            Image(systemName: symbol).foregroundStyle(.secondary).font(.system(size: 11))
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 11))
        case .declined:
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange).font(.system(size: 11))
        case .interrupted:
            Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.system(size: 11))
        }
    }
}

/// `+a −d` for a unified diff snippet.
struct DiffCounts: View {
    let diff: String?

    var body: some View {
        let (adds, dels) = Self.counts(diff)
        HStack(spacing: 3) {
            if adds > 0 { Text("+\(adds)").foregroundStyle(Color.readableGreen) }
            if dels > 0 { Text("−\(dels)").foregroundStyle(.red) }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
    }

    static func counts(_ diff: String?) -> (Int, Int) {
        guard let diff else { return (0, 0) }
        var adds = 0, dels = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { adds += 1 } else if line.hasPrefix("-") { dels += 1 }
        }
        return (adds, dels)
    }
}

/// Selectable monospaced output, clipped to `maxLines` with an expander.
struct MonospaceBlock: View {
    let text: String
    var maxLines: Int = 1_000
    @State private var showAll = false

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let clipped = !showAll && lines.count > maxLines
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(clipped ? lines.suffix(maxLines).joined(separator: "\n") : text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(8)
            }
            if clipped {
                Button("Show all \(lines.count) lines") { showAll = true }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding([.horizontal, .bottom], 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Compact rendering of a unified diff snippet (hunks only, no file
/// headers), tinted like the diff tab.
struct InlineDiffView: View {
    let diff: String
    var maxLines = 400

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let raw = String(line)
                    let kind = DiffLineTint.kind(ofRawLine: raw)
                    Text(raw.isEmpty ? " " : raw)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(kind == nil ? Color.secondary : Color.primary)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(kind.map(DiffLineTint.background) ?? DiffLineTint.headerBackground)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Plan, notices

struct PlanCardView: View {
    let box: ChatItemBox
    @State private var expanded = true

    var body: some View {
        if case let .plan(text) = box.item.content, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "list.bullet.clipboard")
                        Text("Plan").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(expanded ? 0 : -90))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    MarkdownView(blocks: MarkdownParser.parse(text), style: .chat)
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        }
    }
}

struct NoticeView: View {
    let box: ChatItemBox

    var body: some View {
        if case let .notice(notice) = box.item.content {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(notice.level))
                    .foregroundStyle(color(notice.level))
                Text(notice.text)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.system(size: 13))
        }
    }

    private func icon(_ level: AgentItem.Notice.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private func color(_ level: AgentItem.Notice.Level) -> Color {
        switch level {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

struct CompactionView: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
            Text("Context compacted").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 0.5)
        }
    }
}

struct AttachmentThumbnail: View {
    let url: URL
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }
}
