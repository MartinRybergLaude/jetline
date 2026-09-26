import AppKit

/// Per-thread state that must outlive recycled row views.
struct PRThreadUIState: Equatable {
    var isReplying = false
    var replyText = ""
    var isSubmitting = false
    var isResolving = false
    var errorMessage: String?
    /// One-shot: the reply editor takes focus on its next mount.
    var focusReply = false
}

/// What the PR timeline's rows need from their controller.
@MainActor
protocol PRTimelineHost: AnyObject {
    func isExpanded(_ key: String, default value: Bool) -> Bool
    func toggle(_ key: String, default value: Bool, row: String)
    func threadState(_ id: String) -> PRThreadUIState
    func updateThread(_ id: String, _ change: (inout PRThreadUIState) -> Void)
    func replyTextChanged(thread id: String, text: String)
    /// The reply field grew or shrank.
    func threadLayoutChanged(_ id: String)
    func submitReply(thread: PRReviewThread, thenResolve: Bool)
    func setResolved(thread: PRReviewThread, resolved: Bool)
}

/// Node trees for the PR panel's conversation: the description, comments,
/// review summaries and inline threads. Same look as the SwiftUI cards they
/// replace, built on the chat timeline's nodes so every row's height is
/// exact before it scrolls into view.
@MainActor
enum PRTimelineNodes {
    static var style: MarkdownStyle {
        var style = MarkdownStyle.comment
        style.monoFamily = MonoFont.family
        return style
    }

    static var compactStyle: MarkdownStyle {
        var style = MarkdownStyle.compact
        style.monoFamily = MonoFont.family
        return style
    }

    // MARK: Fonts

    private static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    private static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        MonoFont.ns(size: size, weight: weight)
    }

    private static func label(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor, truncation: NSLineBreakMode = .byTruncatingTail, toolTip: String? = nil) -> LabelNode {
        LabelNode(text, font: font, color: color, truncation: truncation, toolTip: toolTip)
    }

    // MARK: Chrome

    /// `cardSurface`: a raised fill under an optional tint, with a hairline.
    static func card(_ child: ChatNode, padding: CGFloat = 10, raised: Bool = true, tint: NSColor? = nil, stroke: NSColor? = .inspectorCardStroke) -> ChatNode {
        let inner = BoxNode(child, padding: NSEdgeInsets(h: padding, v: padding), fill: tint, border: stroke, radius: 10)
        return raised ? BoxNode(inner, fill: .inspectorCard, radius: 10) : inner
    }

    private static func linkButton(_ url: String, help: String = "Open on GitHub") -> ChatNode? {
        guard let link = URL(string: url) else { return nil }
        return ClickNode(SymbolNode("arrow.up.right.square", size: 12, toolTip: help), pointingCursor: true) {
            NSWorkspace.shared.open(link)
        }
    }

    private static func pill(_ text: String, color: NSColor) -> ChatNode {
        BoxNode(
            label(text, mono(10, .bold), color),
            padding: NSEdgeInsets(h: 4, v: 1),
            fill: color.withAlphaComponent(0.15),
            radius: 3,
            hug: true
        )
    }

    private static func markdown(_ blocks: [MarkdownBlock], style: MarkdownStyle, row: String, key: String, host: PRTimelineHost) -> ChatNode {
        ChatMarkdown.node(blocks, options: ChatMarkdown.Options(
            style: style,
            breakout: false,
            isExpanded: { [weak host] key in host?.isExpanded(key, default: false) ?? false },
            toggle: { [weak host] key in host?.toggle(key, default: false, row: row) }
        ), key: key)
    }

    // MARK: Comments

    enum CommentRole {
        case description, comment, threadComment
    }

    static func comment(_ comment: PRComment, role: CommentRole, row: String, host: PRTimelineHost) -> ChatNode {
        var header: [ChatNode] = [
            AvatarNode(url: comment.avatarURL, login: comment.author),
            label(comment.author, font(12, .semibold)),
            label(RelativeTime.string(for: comment.createdAt), font(12), .secondaryLabelColor),
        ]
        if role == .description {
            header.append(BoxNode(
                label("description", font(10.5, .medium), .secondaryLabelColor),
                padding: NSEdgeInsets(h: 4, v: 1),
                fill: .secondary(0.12),
                radius: 3,
                hug: true
            ))
        }
        header.append(FillNode())
        if let link = linkButton(comment.url) { header.append(link) }
        let flexible = header.count - (URL(string: comment.url) == nil ? 1 : 2)

        let body: ChatNode
        let revealKey = "reveal:" + comment.id
        if comment.isMinimized && !host.isExpanded(revealKey, default: false) {
            let reason = comment.minimizedReason.map { " (\($0.lowercased()))" } ?? ""
            body = ClickNode(label("Hidden\(reason) — show", font(12), .secondaryLabelColor), pointingCursor: true) { [weak host] in
                host?.toggle(revealKey, default: false, row: row)
            }
        } else {
            body = markdown(comment.blocks, style: role == .threadComment ? compactStyle : style, row: row, key: comment.id, host: host)
        }

        let content = VStackNode([
            HStackNode(header, spacing: 6, flexible: [flexible], compressible: [1]),
            body,
        ], spacing: 6)
        return role == .threadComment ? content : card(content)
    }

    // MARK: Reviews

    static func review(_ review: PRReview, row: String, host: PRTimelineHost) -> ChatNode {
        let (symbol, color): (String, NSColor) = {
            switch review.verdict {
            case .approved:         return ("checkmark.circle.fill", .readableGreen)
            case .changesRequested: return ("xmark.circle.fill", .systemRed)
            case .commented:        return ("text.bubble", .secondaryLabelColor)
            case .dismissed:        return ("minus.circle", .secondaryLabelColor)
            }
        }()
        var header: [ChatNode] = [
            AvatarNode(url: review.avatarURL, login: review.author, badge: (symbol, color)),
            label("\(review.author) \(review.verdict.label)", font(12, .medium)),
            label(RelativeTime.string(for: review.submittedAt), font(12), .secondaryLabelColor),
            FillNode(),
        ]
        if let link = linkButton(review.url) { header.append(link) }
        var parts: [ChatNode] = [HStackNode(header, spacing: 6, flexible: [3], compressible: [1])]
        if !review.blocks.isEmpty {
            parts.append(markdown(review.blocks, style: style, row: row, key: review.id, host: host))
        }
        // Tinted by `secondary(_:)` rather than a flat alpha for the grey
        // verdicts: the label color already carries its own alpha.
        let isGrey = review.verdict == .commented || review.verdict == .dismissed
        return card(
            VStackNode(parts, spacing: 6),
            tint: isGrey ? .secondary(0.07) : color.withAlphaComponent(0.07),
            stroke: isGrey ? .secondary(0.25) : color.withAlphaComponent(0.25)
        )
    }

    // MARK: Threads

    /// Unresolved threads open expanded and resolved ones collapsed to a
    /// single line: the panel exists to work through what's outstanding.
    static func thread(_ thread: PRReviewThread, row: String, host: PRTimelineHost) -> ChatNode {
        let expandKey = "thread:" + thread.id
        let expanded = host.isExpanded(expandKey, default: !thread.isResolved)
        let ui = host.threadState(thread.id)

        var trailing: [ChatNode] = []
        if thread.isOutdated { trailing.append(pill("OUTDATED", color: .secondaryLabelColor)) }
        if thread.isResolved {
            trailing.append(pill("RESOLVED", color: .readableGreen))
        } else {
            trailing.append(label("\(thread.comments.count)", mono(11.5), .secondaryLabelColor))
        }
        let header = ClickNode(HStackNode(
            [
                BoxNode(SymbolNode(expanded ? "chevron.down" : "chevron.right", size: 10.5), width: 12),
                label(thread.location, mono(12.5), truncation: .byTruncatingHead, toolTip: thread.path),
                FillNode(),
            ] + trailing,
            spacing: 6,
            flexible: [2],
            compressible: [1]
        )) { [weak host] in
            host?.toggle(expandKey, default: !thread.isResolved, row: row)
        }

        var parts: [ChatNode] = [header]
        if expanded {
            if !thread.diffHunkLines.isEmpty {
                parts.append(hunk(thread.diffHunkLines, id: thread.id, row: row, host: host))
            }
            parts.append(VStackNode(
                thread.comments.map { comment(_: $0, role: .threadComment, row: row, host: host) },
                spacing: 10
            ))
            parts.append(actions(thread, ui: ui, host: host))
            if let error = ui.errorMessage {
                parts.append(TextNode(NSAttributedString(string: error, attributes: [
                    .font: font(12), .foregroundColor: NSColor.systemRed,
                ])))
            }
        } else {
            parts.append(preview(thread))
        }

        return card(
            VStackNode(parts, spacing: 8),
            raised: !thread.isResolved,
            tint: thread.isResolved ? .secondary(0.04) : nil,
            stroke: thread.isResolved ? .inspectorCardStroke : NSColor.systemOrange.withAlphaComponent(0.35)
        )
    }

    private static func preview(_ thread: PRReviewThread) -> ChatNode {
        let flattened = (thread.comments.first?.body ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let snippet = flattened.count > 160 ? String(flattened.prefix(160)) + "…" : flattened
        return HStackNode([
            label(thread.comments.first?.author ?? "", font(12, .semibold), .secondaryLabelColor),
            label(snippet, font(12), .secondaryLabelColor),
        ], spacing: 6, flexible: [1])
    }

    /// The diff context GitHub attaches to the thread. The commented line
    /// is the last, so only the tail shows until asked.
    private static func hunk(_ lines: [String], id: String, row: String, host: PRTimelineHost) -> ChatNode {
        let tail = 8
        let key = "hunk:" + id
        let showAll = host.isExpanded(key, default: false)
        let hidden = max(0, lines.count - tail)
        let shown = showAll ? lines : Array(lines.suffix(tail))

        let text = NSMutableAttributedString()
        let lineFont = mono(11.5)
        for (index, line) in shown.enumerated() {
            let kind = DiffLineTint.kind(ofRawLine: line)
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = 6
            paragraph.headIndent = 6
            paragraph.paragraphSpacingBefore = 1
            paragraph.paragraphSpacing = 1
            var attributes: [NSAttributedString.Key: Any] = [
                .font: lineFont,
                .foregroundColor: kind == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if let tint = kind.map(DiffLineTint.backgroundColor) ?? DiffLineTint.headerBackgroundColor {
                attributes[.chatLineTint] = tint
            }
            text.append(NSAttributedString(string: (line.isEmpty ? " " : line) + (index < shown.count - 1 ? "\n" : ""), attributes: attributes))
        }

        var parts: [ChatNode] = []
        if hidden > 0 && !showAll {
            parts.append(ClickNode(BoxNode(
                label("⌃ \(hidden) more line\(hidden == 1 ? "" : "s")", mono(11.5), .secondaryLabelColor),
                padding: NSEdgeInsets(h: 6, v: 2),
                fill: .secondary(0.08)
            ), pointingCursor: true) { [weak host] in
                host?.toggle(key, default: false, row: row)
            })
        }
        parts.append(HScrollNode(TextNode(text, wraps: false, trailingPad: 6), fillViewport: true))
        return BoxNode(VStackNode(parts), border: .secondary(0.15), radius: 4)
    }

    private static func actions(_ thread: PRReviewThread, ui: PRThreadUIState, host: PRTimelineHost) -> ChatNode {
        let id = thread.id
        let canResolve = !thread.isResolved && thread.viewerCanResolve
        let hasText = ui.replyText.nonBlank != nil

        if ui.isReplying {
            var buttons: [ChatNode] = [
                ButtonNode("Cancel", enabled: !ui.isSubmitting) { [weak host] in
                    host?.updateThread(id) { state in
                        state.isReplying = false
                        state.replyText = ""
                        state.errorMessage = nil
                    }
                },
                FillNode(),
            ]
            if canResolve {
                buttons.append(ButtonNode("Reply & resolve", enabled: hasText && !ui.isSubmitting) { [weak host] in
                    host?.submitReply(thread: thread, thenResolve: true)
                })
            }
            let field = ReplyFieldNode(
                text: ui.replyText,
                canSend: hasText,
                isSending: ui.isSubmitting,
                focus: ui.focusReply,
                onChange: { [weak host] text in host?.replyTextChanged(thread: id, text: text) },
                onSubmit: { [weak host] in host?.submitReply(thread: thread, thenResolve: false) },
                onHeightChange: { [weak host] in host?.threadLayoutChanged(id) }
            )
            return VStackNode([field, HStackNode(buttons, spacing: 6, flexible: [1])], spacing: 6)
        }

        var items: [ChatNode] = []
        if thread.viewerCanReply {
            items.append(ButtonNode("Reply") { [weak host] in
                host?.updateThread(id) { state in
                    state.isReplying = true
                    state.focusReply = true
                }
            })
        }
        items.append(FillNode())
        if thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
            if ui.isResolving { items.append(SpinnerNode(diameter: 10)) }
            items.append(ButtonNode(thread.isResolved ? "Unresolve" : "Resolve", enabled: !ui.isSubmitting && !ui.isResolving) { [weak host] in
                host?.setResolved(thread: thread, resolved: !thread.isResolved)
            })
        } else if let resolvedBy = thread.resolvedBy {
            items.append(label("Resolved by \(resolvedBy)", font(12), .secondaryLabelColor))
        }
        let flexible = thread.viewerCanReply ? 1 : 0
        return HStackNode(items, spacing: 8, flexible: [flexible])
    }

    // MARK: Notes

    static func note(_ text: String) -> ChatNode {
        TextNode(NSAttributedString(string: text, attributes: [
            .font: font(12), .foregroundColor: NSColor.secondaryLabelColor,
        ]))
    }
}

// MARK: - Avatar

/// Circular GitHub avatar, falling back to the login's initial on a color
/// derived from the login. An optional verdict badge rides its corner.
final class AvatarNode: ChatNode {
    let url: String?
    let login: String
    let badge: (symbol: String, color: NSColor)?

    static let side: CGFloat = 18
    private static let badgeSide: CGFloat = 10
    private static let badgeOffset: CGFloat = 3

    init(url: String?, login: String, badge: (String, NSColor)? = nil) {
        self.url = url
        self.login = login
        self.badge = badge.map { (symbol: $0.0, color: $0.1) }
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let side = Self.side + (badge == nil ? 0 : Self.badgeOffset)
        return CGSize(width: side, height: side)
    }

    override var viewType: NSView.Type { PRAvatarView.self }
    override func makeView() -> NSView { PRAvatarView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? PRAvatarView else { return }
        view.set(url: url, login: login, badge: badge)
    }
}

final class PRAvatarView: NSView {
    private var url: String?
    private var login = ""
    private var badge: (symbol: String, color: NSColor)?
    private var observer: NSObjectProtocol?

    override var isFlipped: Bool { true }

    func set(url: String?, login: String, badge: (symbol: String, color: NSColor)?) {
        guard url != self.url || login != self.login || badge?.symbol != self.badge?.symbol else { return }
        self.url = url
        self.login = login
        self.badge = badge
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AvatarLoader.didLoad, object: nil, queue: .main) { [weak self] note in
            let loaded = note.object as? String
            MainActor.assumeIsolated {
                guard let self, loaded == self.url else { return }
                self.needsDisplay = true
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSRect(x: 0, y: 0, width: AvatarNode.side, height: AvatarNode.side)
        let path = NSBezierPath(ovalIn: circle)
        if let url, let image = AvatarLoader.shared.image(for: url) {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            image.draw(in: circle, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Self.tint(for: login).setFill()
            path.fill()
            let initial = login.first.map { String($0).uppercased() } ?? "?"
            let font = NSFont.systemFont(ofSize: AvatarNode.side * 0.55, weight: .semibold)
            let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: font.pointSize) } ?? font
            let text = NSAttributedString(string: initial, attributes: [.font: rounded, .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
        }
        // Bots and light-on-white avatars need an edge to read as a disc.
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()

        if let badge {
            let side: CGFloat = 10
            let rect = NSRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if let image = ChatSymbols.image(badge.symbol, size: 8, weight: .regular) {
                let tinted = NSImage(size: image.size, flipped: false) { drawRect in
                    image.draw(in: drawRect)
                    badge.color.set()
                    drawRect.fill(using: .sourceAtop)
                    return true
                }
                let origin = NSPoint(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2)
                tinted.draw(in: NSRect(origin: origin, size: image.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    /// Stable per login so the same person keeps the same color across
    /// launches — `hashValue` is seeded per process and would not.
    private static func tint(for login: String) -> NSColor {
        var hash: UInt64 = 5381
        for byte in login.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return NSColor(hue: CGFloat(hash % 360) / 360, saturation: 0.45, brightness: 0.65, alpha: 1)
    }
}

// MARK: - Button

/// A small push button.
final class ButtonNode: ChatNode {
    let title: String
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.enabled = enabled
        self.action = action
    }

    private static let measuring = PRButton.make()

    override func measure(_ width: CGFloat) -> CGSize {
        Self.measuring.title = title
        let size = Self.measuring.fittingSize
        return CGSize(width: min(width, ceil(size.width)), height: ceil(size.height))
    }

    override var viewType: NSView.Type { PRButton.self }
    override func makeView() -> NSView { PRButton.make() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let button = view as? PRButton else { return }
        if button.title != title { button.title = title }
        button.isEnabled = enabled
        button.handler = action
    }
}

final class PRButton: NSButton {
    var handler: (() -> Void)?

    static func make() -> PRButton {
        let button = PRButton(frame: .zero)
        button.bezelStyle = .push
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.target = button
        button.action = #selector(fire)
        return button
    }

    @objc private func fire() { handler?() }
}

// MARK: - Reply field

/// `CommentFieldView` in a thread card, as tall as its text.
final class ReplyFieldNode: ChatNode {
    let text: String
    let canSend: Bool
    let isSending: Bool
    /// Cleared once used: the cached node is re-configured whenever its
    /// row remounts, and only the first should take focus.
    private var focus: Bool
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onHeightChange: () -> Void

    init(text: String, canSend: Bool, isSending: Bool, focus: Bool, onChange: @escaping (String) -> Void, onSubmit: @escaping () -> Void, onHeightChange: @escaping () -> Void) {
        self.text = text
        self.canSend = canSend
        self.isSending = isSending
        self.focus = focus
        self.onChange = onChange
        self.onSubmit = onSubmit
        self.onHeightChange = onHeightChange
    }

    override func measure(_ width: CGFloat) -> CGSize {
        CGSize(width: width, height: CommentFieldView.height(for: text, width: width))
    }

    override var viewType: NSView.Type { CommentFieldView.self }
    override func makeView() -> NSView { CommentFieldView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let field = view as? CommentFieldView else { return }
        field.onChange = onChange
        field.onSubmit = onSubmit
        field.onHeightChange = onHeightChange
        field.set(text: text, placeholder: "Reply…", canSend: canSend, isSending: isSending, sendHelp: "Reply (⌘↩)")
        if focus {
            focus = false
            field.focus()
        }
    }
}
