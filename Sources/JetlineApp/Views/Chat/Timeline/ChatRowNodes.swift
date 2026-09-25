import AppKit

/// What row content needs from the timeline: per-row UI state that must
/// outlive recycled views, and actions.
@MainActor
protocol ChatRowHost: AnyObject {
    var cwd: String { get }
    var markdownStyle: MarkdownStyle { get }
    func isExpanded(_ key: String, default value: Bool) -> Bool
    func toggle(_ key: String, default value: Bool, row: String)
    func value(for key: String) -> String?
    func setValue(_ value: String?, for key: String, row: String)
    func confirmRevert(turn: String)
    /// Per-file diffs of a turn's changes; `nil` while they load.
    func changedFiles(row: String, from: String, to: String) -> [FileDiff]?
}

/// Builds the node tree for one row.
@MainActor
enum ChatRowNodes {
    /// The row's root and the height its content reaches into the gap
    /// below it (a hover bar), which the gap then gives back unless it
    /// must clear the bar.
    static func root(for row: ChatRow, host: ChatRowHost) -> RowRootNode {
        let (node, reach) = content(for: row, host: host)
        return RowRootNode(node, gap: row.gapClearsBar ? row.gap : max(0, row.gap - reach))
    }

    private static func content(for row: ChatRow, host: ChatRowHost) -> (ChatNode, CGFloat) {
        switch row.content {
        case let .spacer(height):
            return (FillNode(height: height), 0)
        case let .user(text, images, timestamp, canRevert):
            let hover = user(text: text, images: images, timestamp: timestamp, revert: canRevert ? { [weak host] in
                host?.confirmRevert(turn: row.turnId)
            } : nil)
            // Keep clear of the left edge, like a chat bubble.
            return (BoxNode(VStackNode([hover], align: .trailing), padding: NSEdgeInsets(top: 0, left: 60, bottom: 0, right: 0)), hover.reach)
        case let .assistant(text, timestamp, streaming, copyText):
            let markdown = ChatMarkdown.node(text, options: markdownOptions(row: row.id, host: host, breakout: true), key: row.id)
            guard let copyText else { return (markdown, 0) }
            let hover = HoverNode(
                markdown,
                bar: actionBar(timestampFirst: false, text: copyText, timestamp: timestamp, revert: nil),
                edge: .leading,
                gap: 6,
                enabled: !streaming,
                pinned: row.pinsActions
            )
            return (hover, hover.reach)
        case let .work(items, isLive):
            return (workGroup(items: items, isLive: isLive, row: row.id, host: host), 0)
        case let .plan(text):
            return (plan(text: text, row: row.id, host: host), 0)
        case let .notice(notice):
            return (self.notice(notice), 0)
        case .compaction:
            return (compaction(), 0)
        case let .footer(footer):
            return (self.footer(footer, row: row.id, host: host), 0)
        }
    }

    static func markdownOptions(row: String, host: ChatRowHost, breakout: Bool, style: MarkdownStyle? = nil) -> ChatMarkdown.Options {
        ChatMarkdown.Options(
            style: style ?? host.markdownStyle,
            breakout: breakout,
            isExpanded: { [weak host] key in host?.isExpanded(key, default: false) ?? false },
            toggle: { [weak host] key in host?.toggle(key, default: false, row: row) }
        )
    }

    // MARK: Fonts

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func string(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static let bodyLineHeight = ChatFonts.lineHeight(.systemFont(ofSize: 14))

    // MARK: Messages

    private static func user(text: String, images: [String], timestamp: Date?, revert: (() -> Void)?) -> HoverNode {
        var parts: [ChatNode] = []
        if !images.isEmpty {
            // One image shows large; several share the row.
            let side: CGFloat = images.count == 1 ? 280 : 160
            parts.append(HStackNode(images.map { ThumbNode(path: $0, gallery: images, maxSide: side) }, spacing: 8))
        }
        if !text.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            let body = NSAttributedString(string: text, attributes: [
                .font: font(15),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ])
            parts.append(BoxNode(
                TextNode(body, hug: true),
                padding: NSEdgeInsets(h: 16, v: 11),
                fill: .secondary(0.12),
                radius: 8,
                hug: true
            ))
        }
        return HoverNode(
            VStackNode(parts, spacing: 6, align: .trailing),
            bar: actionBar(timestampFirst: true, text: text, timestamp: timestamp, revert: revert),
            edge: .trailing,
            gap: 6,
            enabled: true
        )
    }

    /// Revert / copy / time, shown below a message on hover.
    private static func actionBar(timestampFirst: Bool, text: String, timestamp: Date?, revert: (() -> Void)?) -> ChatNode {
        let time: ChatNode? = timestamp.map { date in
            let label = LabelNode(
                string(format(date), .monospacedDigitSystemFont(ofSize: 12, weight: .regular), .secondaryLabelColor),
                toolTip: date.formatted(date: .complete, time: .shortened)
            )
            // Digits sit above the line box's descender space; lift the
            // box so they center on the icons.
            let padding = timestampFirst
                ? NSEdgeInsets(top: 0, left: 0, bottom: 1.5, right: 4)
                : NSEdgeInsets(top: 0, left: 4, bottom: 1.5, right: 0)
            return BoxNode(label, padding: padding, hug: true)
        }
        var items: [ChatNode] = []
        if timestampFirst, let time { items.append(time) }
        items.append(IconButtonNode("doc.on.doc", help: "Copy", flashSymbol: "checkmark") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        })
        if let revert {
            items.append(IconButtonNode("arrow.uturn.backward", help: "Revert to before this message", action: revert))
        }
        if !timestampFirst, let time { items.append(time) }
        return HStackNode(items, spacing: 2)
    }

    /// Time only for today; the date too before that.
    private static func format(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    // MARK: Work

    /// Tool calls and reasoning of one stretch of a turn: a summary line
    /// that opens to a card of the calls.
    private static func workGroup(items: [AgentItem], isLive: Bool, row: String, host: ChatRowHost) -> ChatNode {
        let key = "work:" + row
        let expanded = host.isExpanded(key, default: false)
        let live = items.contains { $0.status == .inProgress && $0.parentId == nil }
        let title = GlowNode(HStackNode([
            LabelNode(summary(items), font: font(14)),
            SymbolNode(expanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold, color: .labelColor),
        ], spacing: 6, compressible: [0]), live: live)
        let header = ClickNode(HStackNode([title, FillNode()], spacing: 0, flexible: [1], compressible: [0])) { [weak host] in
            host?.toggle(key, default: false, row: row)
        }
        guard expanded else { return header }
        var rows: [ChatNode] = []
        for item in items {
            if !rows.isEmpty { rows.append(FillNode(height: 1, color: .secondary(0.18))) }
            rows.append(workRow(item, row: row, host: host))
        }
        return VStackNode([
            header,
            BoxNode(VStackNode(rows), border: .secondary(0.18), radius: 10),
        ], spacing: 8)
    }

    /// "Ran 2 commands, edited a file": counts by kind. While something
    /// runs, just what's running: "Running a command".
    private static func summary(_ items: [AgentItem]) -> String {
        enum Kind: CaseIterable { case command, edit, read, search, agent, tool, thought }
        func kind(_ item: AgentItem) -> (Kind, Int)? {
            switch item.content {
            case .command: return (.command, 1)
            case let .fileChange(change): return (.edit, max(change.edits.count, 1))
            case let .tool(tool): return (tool.summary?.hasPrefix("Read") == true ? .read : .tool, 1)
            case .webSearch: return (.search, 1)
            case .subagent: return (.agent, 1)
            case .reasoning: return (.thought, 1)
            default: return nil
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String {
            n == 1 ? one : "\(n) \(many)"
        }
        func phrase(_ kind: Kind, _ n: Int, live: Bool) -> String {
            switch kind {
            case .command: return (live ? "running " : "ran ") + count(n, "a command", "commands")
            case .edit: return (live ? "editing " : "edited ") + count(n, "a file", "files")
            case .read: return (live ? "reading " : "read ") + count(n, "a file", "files")
            case .search: return live ? "searching the web" : (n == 1 ? "searched the web" : "searched the web \(n) times")
            case .agent: return (live ? "running " : "ran ") + count(n, "a subagent", "subagents")
            case .tool: return (live ? "using " : "used ") + count(n, "a tool", "tools")
            case .thought: return live ? "thinking" : "thought"
            }
        }

        let running = items.filter { $0.status == .inProgress && $0.parentId == nil }
        let live = !running.isEmpty
        var counts: [Kind: Int] = [:]
        for item in live ? running : items {
            if let (kind, n) = kind(item) { counts[kind, default: 0] += n }
        }
        // Thinking only counts when nothing else happened.
        if counts.count > 1 { counts[.thought] = nil }
        let text = Kind.allCases.compactMap { kind in
            counts[kind].map { phrase(kind, $0, live: live) }
        }.joined(separator: ", ")
        guard let first = text.first else { return live ? "Working…" : "" }
        return first.uppercased() + text.dropFirst()
    }

    /// "Ran git push ›": a verb, what it acted on, and a chevron when
    /// there's detail to open.
    private static func workRow(_ item: AgentItem, row: String, host: ChatRowHost) -> ChatNode {
        let key = "item:" + item.id
        let detail = hasDetail(item)
        let expanded = detail && host.isExpanded(key, default: false)
        let nested: CGFloat = item.parentId == nil ? 0 : 16
        let (verb, subject) = title(item, host: host)

        var line: [ChatNode] = [LabelNode(verb, font: font(14), color: .secondaryLabelColor)]
        var compressible: Set<Int> = []
        for (node, truncates) in subject {
            if truncates { compressible.insert(line.count) }
            line.append(node)
        }
        switch item.status {
        case .inProgress: line.append(SpinnerNode(diameter: 12))
        case .failed: line.append(LabelNode("failed", font: font(13), color: .systemRed))
        case .declined: line.append(LabelNode("declined", font: font(13), color: .systemOrange))
        case .interrupted: line.append(LabelNode("stopped", font: font(13), color: .secondaryLabelColor))
        case .completed: break
        }
        if detail {
            line.append(SymbolNode(expanded ? "chevron.down" : "chevron.right", size: 10, weight: .semibold))
        }
        line.append(FillNode())
        let button = ClickNode(
            BoxNode(
                HStackNode(line, spacing: 5, flexible: [line.count - 1], compressible: compressible),
                padding: NSEdgeInsets(top: 9, left: 14 + nested, bottom: 9, right: 14)
            ),
            enabled: detail
        ) { [weak host] in
            host?.toggle(key, default: false, row: row)
        }

        guard expanded, let detailNode = self.detail(item, row: row, host: host) else { return button }
        return VStackNode([
            button,
            BoxNode(detailNode, padding: NSEdgeInsets(top: 0, left: 14 + nested, bottom: 12, right: 14)),
        ])
    }

    /// A work row's verb, then the pieces it acted on and whether each may
    /// truncate.
    private static func title(_ item: AgentItem, host: ChatRowHost) -> (String, [(ChatNode, Bool)]) {
        let live = item.status == .inProgress
        func label(_ text: String, _ font: NSFont = font(14), _ color: NSColor = .labelColor) -> (ChatNode, Bool) {
            (LabelNode(text, font: font, color: color), true)
        }
        switch item.content {
        case let .command(command):
            let first = command.command.split(whereSeparator: \.isNewline).first.map(String.init) ?? command.command
            var parts = [label(first + (command.command.contains("\n") ? "…" : ""))]
            if let code = command.exitCode, code != 0 {
                parts.append((LabelNode("exit \(code)", font: font(13), color: .systemRed), false))
            }
            return (live ? "Running" : "Ran", parts)
        case let .fileChange(change):
            let paths = change.edits.map { relative($0.path, cwd: host.cwd) }.joined(separator: ", ").nonBlank ?? "a file"
            var parts = [label(paths)]
            if let counts = diffCounts(change.edits.first?.diff) {
                parts.append((LabelNode(counts), false))
            }
            return (live ? "Editing" : "Edited", parts)
        case let .tool(tool):
            // Summaries lead with their verb ("Read Package.swift").
            if let summary = tool.summary?.nonBlank {
                let words = summary.split(separator: " ", maxSplits: 1).map(String.init)
                return (words[0], words.count > 1 ? [label(words[1])] : [])
            }
            let name = [tool.server, tool.name].compactMap { $0 }.joined(separator: " · ")
            return (live ? "Using" : "Used", [label(name)])
        case let .webSearch(query):
            return (live ? "Searching for" : "Searched for", [label("“\(query)”")])
        case let .subagent(agent):
            let name = [agent.agentType, agent.description].compactMap { $0 }.joined(separator: ": ")
            return (live ? "Running agent" : "Ran agent", [label(name)])
        case let .reasoning(text):
            let italic = ChatFonts.text(size: 14, family: nil, italic: true)
            return (live ? "Thinking" : "Thought", text.isEmpty ? [] : [label(firstLine(text), italic, .secondaryLabelColor)])
        default:
            return ("", [])
        }
    }

    private static func hasDetail(_ item: AgentItem) -> Bool {
        switch item.content {
        case let .command(command): return !command.output.isEmpty || command.command.contains("\n")
        case let .fileChange(change): return change.edits.contains { $0.diff?.isEmpty == false }
        case let .tool(tool): return tool.input?.object?.isEmpty == false || tool.output?.isEmpty == false
        case let .subagent(agent): return agent.prompt != nil || agent.result != nil
        case let .reasoning(text): return !text.isEmpty
        default: return false
        }
    }

    private static func detail(_ item: AgentItem, row: String, host: ChatRowHost) -> ChatNode? {
        let key = "item:" + item.id
        switch item.content {
        case let .command(command):
            var parts: [ChatNode] = []
            if command.command.contains("\n") {
                parts.append(monospace(command.command, key: key + "#cmd", row: row, host: host))
            }
            if !command.output.isEmpty {
                parts.append(monospace(command.output, maxLines: 40, key: key + "#out", row: row, host: host))
            }
            return VStackNode(parts, spacing: 4)
        case let .fileChange(change):
            let parts: [ChatNode] = change.edits.compactMap { edit in
                guard let diff = edit.diff, !diff.isEmpty else { return nil }
                var stack: [ChatNode] = []
                if change.edits.count > 1 {
                    stack.append(LabelNode(relative(edit.path, cwd: host.cwd), font: font(13, .medium)))
                }
                stack.append(inlineDiff(diff))
                return VStackNode(stack, spacing: 2)
            }
            return VStackNode(parts, spacing: 6)
        case let .tool(tool):
            var parts: [ChatNode] = []
            if let input = tool.input, input.object?.isEmpty == false {
                parts.append(monospace(input.prettyPrinted(), maxLines: 20, key: key + "#in", row: row, host: host))
            }
            if let output = tool.output, !output.isEmpty {
                parts.append(monospace(output, maxLines: 30, key: key + "#out", row: row, host: host))
            }
            return VStackNode(parts, spacing: 4)
        case let .subagent(agent):
            var parts: [ChatNode] = []
            if let prompt = agent.prompt {
                parts.append(TextNode(string(prompt, font(14), .secondaryLabelColor)))
            }
            if let result = agent.result, !result.isEmpty {
                let options = markdownOptions(row: row, host: host, breakout: false, style: .comment)
                parts.append(ChatMarkdown.node(result, options: options, key: key))
            }
            return VStackNode(parts, spacing: 6)
        case let .reasoning(text):
            return TextNode(string(text, font(14), .secondaryLabelColor))
        default:
            return nil
        }
    }

    /// Selectable monospaced output, clipped to its last `maxLines` with an
    /// expander.
    private static func monospace(_ text: String, maxLines: Int = 1_000, key: String, row: String, host: ChatRowHost) -> ChatNode {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let clipped = lines.count > maxLines && !host.isExpanded(key, default: false)
        let shown = clipped ? lines.suffix(maxLines).joined(separator: "\n") : text
        var parts: [ChatNode] = [
            HScrollNode(BoxNode(TextNode(string(shown, mono(13)), wraps: false), padding: NSEdgeInsets(h: 8, v: 8), hug: true)),
        ]
        if clipped {
            let link = ClickNode(LabelNode("Show all \(lines.count) lines", font: font(13), color: .linkColor), pointingCursor: true) { [weak host] in
                host?.toggle(key, default: false, row: row)
            }
            parts.append(BoxNode(VStackNode([link], align: .leading), padding: NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)))
        }
        return BoxNode(VStackNode(parts), fill: .secondary(0.08), radius: 6)
    }

    /// A unified diff snippet, lines tinted edge to edge like the diff tab.
    static func inlineDiff(_ diff: String, maxLines: Int = 400) -> ChatNode {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 8
        paragraph.headIndent = 8
        let text = NSMutableAttributedString()
        let font = mono(13)
        for (index, line) in lines.enumerated() {
            let raw = String(line)
            let kind = DiffLineTint.kind(ofRawLine: raw)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: kind == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if let tint = kind.map(DiffLineTint.backgroundColor) ?? DiffLineTint.headerBackgroundColor {
                attributes[.chatLineTint] = tint
            }
            let terminator = index < lines.count - 1 ? "\n" : ""
            text.append(NSAttributedString(string: (raw.isEmpty ? " " : raw) + terminator, attributes: attributes))
        }
        return BoxNode(
            HScrollNode(TextNode(text, wraps: false, trailingPad: 8), fillViewport: true),
            padding: NSEdgeInsets(v: 4),
            fill: .secondary(0.05),
            radius: 6
        )
    }

    /// `+a −d` for a unified diff snippet.
    private static func diffCounts(_ diff: String?) -> NSAttributedString? {
        guard let diff else { return nil }
        var adds = 0, dels = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { adds += 1 } else if line.hasPrefix("-") { dels += 1 }
        }
        return counts(adds: adds, dels: dels, font: mono(13, .medium), showZero: false)
    }

    private static func counts(adds: Int, dels: Int, font: NSFont, showZero: Bool) -> NSAttributedString? {
        let out = NSMutableAttributedString()
        if showZero || adds > 0 { out.append(string("+\(adds)", font, .readableGreen)) }
        if showZero || dels > 0 {
            if out.length > 0 { out.append(string(" ", font)) }
            out.append(string("−\(dels)", font, .systemRed))
        }
        return out.length > 0 ? out : nil
    }

    private static func relative(_ path: String, cwd: String) -> String {
        path.hasPrefix(cwd + "/") ? String(path.dropFirst(cwd.count + 1)) : path
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.replacingOccurrences(of: "**", with: "")
    }

    // MARK: Plan, notices

    private static func plan(text: String, row: String, host: ChatRowHost) -> ChatNode {
        let key = "plan:" + row
        let expanded = host.isExpanded(key, default: true)
        let header = ClickNode(HStackNode([
            SymbolNode("list.bullet.clipboard", size: 14),
            LabelNode("Plan", font: font(14, .semibold), color: .secondaryLabelColor),
            FillNode(),
            BoxNode(SymbolNode(expanded ? "chevron.down" : "chevron.right", size: 12), width: 14),
        ], spacing: 6, flexible: [2])) { [weak host] in
            host?.toggle(key, default: true, row: row)
        }
        var parts: [ChatNode] = [header]
        if expanded {
            // Tables stay inside the card.
            parts.append(ChatMarkdown.node(text, options: markdownOptions(row: row, host: host, breakout: false), key: row))
        }
        return BoxNode(
            VStackNode(parts, spacing: 8),
            padding: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12),
            fill: NSColor.controlAccentColor.withAlphaComponent(0.06),
            border: NSColor.controlAccentColor.withAlphaComponent(0.25),
            radius: 10
        )
    }

    private static func notice(_ notice: AgentItem.Notice) -> ChatNode {
        let (icon, color): (String, NSColor) = {
            switch notice.level {
            case .info: return ("info.circle", .secondaryLabelColor)
            case .warning: return ("exclamationmark.triangle", .systemOrange)
            case .error: return ("xmark.octagon", .systemRed)
            }
        }()
        return HStackNode([
            BoxNode(SymbolNode(icon, size: 14, color: color), hug: true, height: bodyLineHeight),
            TextNode(string(notice.text, font(14), .secondaryLabelColor)),
        ], spacing: 6, flexible: [1], align: .top)
    }

    private static func compaction() -> ChatNode {
        HStackNode([
            FillNode(height: 0.5, color: .secondary(0.25)),
            LabelNode("Context compacted", font: font(13), color: .secondaryLabelColor),
            FillNode(height: 0.5, color: .secondary(0.25)),
        ], spacing: 8, flexible: [0, 2])
    }

    // MARK: Footer

    private static func footer(_ footer: ChatRow.Footer, row: String, host: ChatRowHost) -> ChatNode {
        switch footer {
        case let .status(since, until, activity, agent):
            let suffix = activity.map { " · " + describe($0, agent: agent) } ?? ""
            return BoxNode(HStackNode([
                SparkNode(side: 16, color: .controlAccentColor, animating: until == nil),
                ElapsedNode(since: since, until: until, suffix: suffix, font: font(14), color: .secondaryLabelColor),
            ], spacing: 10, flexible: [1]), height: 18)
        case let .changes(stat, from, to):
            return changedFiles(stat: stat, from: from, to: to, row: row, host: host)
        case .interrupted:
            return HStackNode([
                SymbolNode("stop.circle", size: 14),
                LabelNode("Interrupted", font: font(14), color: .secondaryLabelColor),
            ], spacing: 6, flexible: [1])
        case let .failed(message):
            return HStackNode([
                BoxNode(SymbolNode("exclamationmark.triangle.fill", size: 14, color: .systemRed), hug: true, height: bodyLineHeight),
                TextNode(string(message, font(14), .systemRed)),
            ], spacing: 6, flexible: [1], align: .top)
        }
    }

    private static func describe(_ activity: ChatRow.Activity, agent: AgentProviderKind) -> String {
        switch activity {
        case .waitingForAgent: return "Waiting for \(agent.displayName)…"
        case .thinking: return "Thinking…"
        case .writing: return "Writing…"
        case .runningTools: return "Running tools…"
        case .waitingForYou: return "Waiting for you"
        }
    }

    /// What a turn changed on disk, from its checkpoints. Expands to the
    /// per-file diffs, loaded on demand.
    private static func changedFiles(stat: Checkpointer.Stat, from: String, to: String, row: String, host: ChatRowHost) -> ChatNode {
        let key = "files:" + row
        let expanded = host.isExpanded(key, default: false)
        var headerItems: [ChatNode] = [
            SymbolNode("doc.on.doc", size: 14),
            LabelNode(stat.files == 1 ? "1 file changed" : "\(stat.files) files changed", font: font(14), color: .secondaryLabelColor),
        ]
        if let counts = counts(adds: stat.additions, dels: stat.deletions, font: mono(13, .medium), showZero: true) {
            headerItems.append(LabelNode(counts))
        }
        headerItems.append(FillNode())
        headerItems.append(BoxNode(SymbolNode(expanded ? "chevron.down" : "chevron.right", size: 12), width: 14))
        let header = ClickNode(BoxNode(
            HStackNode(headerItems, spacing: 8, flexible: [headerItems.count - 2]),
            padding: NSEdgeInsets(h: 10, v: 8)
        )) { [weak host] in
            host?.toggle(key, default: false, row: row)
        }

        var parts: [ChatNode] = [header]
        if expanded {
            parts.append(FillNode(height: 1, color: .separatorColor))
            if let files = host.changedFiles(row: row, from: from, to: to) {
                parts.append(VStackNode(files.map { fileRow($0, row: row, host: host) }))
            } else {
                parts.append(BoxNode(VStackNode([SpinnerNode(diameter: 16)], align: .leading), padding: NSEdgeInsets(h: 10, v: 10)))
            }
        }
        return BoxNode(VStackNode(parts), fill: .secondary(0.05), border: .secondary(0.18), radius: 8)
    }

    private static func fileRow(_ file: FileDiff, row: String, host: ChatRowHost) -> ChatNode {
        let key = "open:" + row
        let isOpen = host.value(for: key) == file.path
        var items: [ChatNode] = [
            statusBadge(file.status),
            LabelNode(file.path, font: font(14), truncation: .byTruncatingMiddle),
            FillNode(),
        ]
        if let counts = counts(adds: file.additions, dels: file.deletions, font: mono(13), showZero: false) {
            items.append(LabelNode(counts))
        }
        let line = ClickNode(BoxNode(
            HStackNode(items, spacing: 8, flexible: [2], compressible: [1]),
            padding: NSEdgeInsets(h: 10, v: 5)
        )) { [weak host] in
            host?.setValue(isOpen ? nil : file.path, for: key, row: row)
        }
        guard isOpen else { return line }
        let body: ChatNode
        if file.isBinary {
            body = BoxNode(LabelNode("Binary file", font: font(13), color: .secondaryLabelColor), padding: NSEdgeInsets(h: 10))
        } else {
            let diff = file.hunks.map { hunk in
                ([hunk.header] + hunk.lines.map { line in
                    switch line.kind {
                    case .addition: return "+" + line.text
                    case .deletion: return "-" + line.text
                    case .context: return " " + line.text
                    }
                }).joined(separator: "\n")
            }.joined(separator: "\n")
            body = BoxNode(inlineDiff(diff), padding: NSEdgeInsets(top: 0, left: 10, bottom: 6, right: 10))
        }
        return VStackNode([line, body], spacing: 4)
    }

    /// Coloured one-letter status chip, as `FileStatusBadge` draws it.
    private static func statusBadge(_ status: FileDiff.Status) -> ChatNode {
        let color: NSColor = {
            switch status {
            case .added: return .systemGreen
            case .deleted: return .systemRed
            case .modified: return .systemBlue
            case .renamed: return .systemOrange
            case .copied: return .systemPurple
            case .typeChange: return .systemGray
            case .unknown: return .secondaryLabelColor
            }
        }()
        return BoxNode(
            LabelNode(status.rawValue, font: mono(9, .bold), color: .white),
            padding: NSEdgeInsets(top: 1, left: 4, bottom: 1, right: 4),
            fill: color,
            radius: 3,
            hug: true,
            toolTip: status.label
        )
    }
}
