#if os(macOS)
import AppKit

// Markdown for the AppKit chat timeline. Flowing blocks (paragraphs,
// headings, lists, quotes) merge into one text view per run, so a selection
// can span them; code blocks, tables, rules and disclosures break the run
// and get views of their own.

extension NSColor {
    /// SwiftUI's `Color.secondary.opacity(x)`: the secondary label color
    /// with its own alpha scaled, where `withAlphaComponent` would replace it.
    @MainActor
    static func secondary(_ opacity: CGFloat) -> NSColor {
        if let hit = ChatColors.secondary[opacity] { return hit }
        let color = NSColor(name: nil) { appearance in
            var result = NSColor.secondaryLabelColor
            appearance.performAsCurrentDrawingAppearance {
                let resolved = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? .gray
                result = resolved.withAlphaComponent(resolved.alphaComponent * opacity)
            }
            return result
        }
        ChatColors.secondary[opacity] = color
        return color
    }
}

@MainActor
private enum ChatColors {
    static var secondary: [CGFloat: NSColor] = [:]
}

@MainActor
enum ChatFonts {
    static func text(size: CGFloat, family: String?, weight: NSFont.Weight? = nil, bold: Bool = false, italic: Bool = false) -> NSFont {
        let base: NSFont
        if let family, let custom = NSFontManager.shared.font(withFamily: family, traits: [], weight: MonoFont.managerWeight(weight), size: size) {
            base = custom
        } else {
            base = .systemFont(ofSize: size, weight: weight ?? .regular)
        }
        return styled(base, bold: bold, italic: italic)
    }

    static func mono(size: CGFloat, family: String?, weight: NSFont.Weight? = nil, bold: Bool = false, italic: Bool = false) -> NSFont {
        styled(MonoFont.ns(size: size, weight: weight ?? .regular, family: family), bold: bold, italic: italic)
    }

    /// Code in `style`, optically matched to its text at `size`.
    static func code(size: CGFloat, style: MarkdownStyle, weight: NSFont.Weight? = nil, bold: Bool = false, italic: Bool = false) -> NSFont {
        let matched = MonoFont.matchedSize(size, textFamily: style.fontFamily, monoFamily: style.monoFamily)
        return mono(size: matched, family: style.monoFamily, weight: weight, bold: bold, italic: italic)
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }
}

/// An `NSCache` value: the cache holds objects only.
final class CacheBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Memoizes inline markdown → styled `NSAttributedString`.
@MainActor
enum ChatInline {
    private static let cache: NSCache<NSString, CacheBox<NSAttributedString>> = {
        let cache = NSCache<NSString, CacheBox<NSAttributedString>>()
        cache.countLimit = 4000
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    static func attributed(
        _ source: String,
        style: MarkdownStyle,
        size: CGFloat,
        weight: NSFont.Weight? = nil,
        secondary: Bool = false
    ) -> NSAttributedString {
        let key = "\(size)|\(style.codeSize)|\(style.fontFamily ?? "")|\(style.monoFamily ?? "")|\(weight?.rawValue ?? 0)|\(secondary ? 1 : 0)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = render(source, style: style, size: size, weight: weight, secondary: secondary)
        cache.setObject(CacheBox(value), forKey: key, cost: source.utf8.count)
        return value
    }

    private static func render(_ source: String, style: MarkdownStyle, size: CGFloat, weight: NSFont.Weight?, secondary: Bool) -> NSAttributedString {
        let math = MarkdownMath.extract(source)
        let parsed = MarkdownInline.parse(math?.source ?? source)
        let out = NSMutableAttributedString()
        let color: NSColor = secondary ? .secondaryLabelColor : .labelColor
        for run in parsed.runs {
            // A soft break inside a paragraph is a line break, not a new
            // paragraph: paragraph spacing must not open up between its lines.
            let text = String(parsed[run.range].characters).replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            let bold = intent.contains(.stronglyEmphasized)
            let italic = intent.contains(.emphasized)
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if intent.contains(.code) {
                attributes[.font] = ChatFonts.code(size: style.codeSize, style: style, weight: weight, bold: bold, italic: italic)
                attributes[.backgroundColor] = NSColor.secondary(0.18)
            } else {
                attributes[.font] = ChatFonts.text(size: size, family: style.fontFamily, weight: weight, bold: bold, italic: italic)
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            if let spans = math?.spans {
                appendMath(text, spans: spans, attributes: attributes, to: out, size: size, codeFont: ChatFonts.code(size: style.codeSize, style: style), secondary: secondary)
            } else {
                out.append(NSAttributedString(string: text, attributes: attributes))
            }
        }
        return out
    }

    /// `text` with each math placeholder swapped for its typeset formula.
    private static func appendMath(
        _ text: String,
        spans: [MarkdownMath.Span],
        attributes: [NSAttributedString.Key: Any],
        to out: NSMutableAttributedString,
        size: CGFloat,
        codeFont: @autoclosure () -> NSFont,
        secondary: Bool
    ) {
        var rest = Substring(text)
        while let open = rest.firstIndex(of: MarkdownMath.open) {
            if open > rest.startIndex {
                out.append(NSAttributedString(string: String(rest[..<open]), attributes: attributes))
            }
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: MarkdownMath.close),
                  let index = Int(rest[after..<close]), spans.indices.contains(index) else {
                rest = rest[after...]
                continue
            }
            out.append(ChatMath.inline(
                spans[index],
                textSize: size,
                secondary: secondary,
                attributes: attributes,
                codeFont: codeFont()
            ))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty {
            out.append(NSAttributedString(string: String(rest), attributes: attributes))
        }
    }
}

/// What a fence's info string asks for.
enum ChatFence {
    case plain, diff, mermaid, math
    case highlighted(SyntaxLanguage)

    init(_ language: String?) {
        switch language {
        case nil: self = .plain
        case "mermaid"?: self = .mermaid
        case "math"?: self = .math
        case "diff"?, "patch"?, "udiff"?: self = .diff
        case let name?: self = SyntaxLanguage.forFence(name).map(ChatFence.highlighted) ?? .plain
        }
    }

    /// The header label: the tag as written, except the ones that only say
    /// "don't highlight this".
    static func label(_ language: String?) -> String {
        guard let language, !["text", "txt", "plain", "plaintext", "none", "ascii"].contains(language) else { return "" }
        return language
    }
}

/// Memoizes highlighted code blocks: a streaming reply rebuilds its nodes
/// on every chunk, and relexing a long block each time adds up. Blocks still
/// streaming in aren't stored: each version is seen once.
@MainActor
enum ChatCode {
    private static let cache: NSCache<NSString, CacheBox<NSAttributedString>> = {
        let cache = NSCache<NSString, CacheBox<NSAttributedString>>()
        cache.countLimit = 500
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    private static func cached(_ key: String, cost: Int, store: Bool, _ build: () -> NSAttributedString) -> NSAttributedString {
        if let hit = cache.object(forKey: key as NSString) { return hit.value }
        let value = build()
        if store { cache.setObject(CacheBox(value), forKey: key as NSString, cost: cost) }
        return value
    }

    static func highlighted(_ code: String, language: SyntaxLanguage, font: NSFont, store: Bool) -> NSAttributedString {
        cached("\(language.name)|\(font.fontName)|\(font.pointSize)|\(code)", cost: code.utf8.count, store: store) {
            let highlighter = SyntaxHighlighter(language: language)
            var state = SyntaxHighlighter.State.normal
            let out = NSMutableAttributedString(string: code, attributes: plain(font))
            var offset = 0
            out.beginEditing()
            for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                for segment in highlighter.tokenize(String(line), state: &state) {
                    let length = segment.text.utf16.count
                    if let kind = segment.kind {
                        out.addAttribute(.foregroundColor, value: SyntaxTheme.color(kind), range: NSRange(location: offset, length: length))
                    }
                    offset += length
                }
                offset += 1
            }
            out.endEditing()
            return out
        }
    }

    static func diff(_ code: String, font: NSFont, indent: CGFloat, store: Bool) -> NSAttributedString {
        cached("diff|\(font.fontName)|\(font.pointSize)|\(indent)|\(code)", cost: code.utf8.count, store: store) {
            DiffLineTint.attributed(code.split(separator: "\n", omittingEmptySubsequences: false), font: font, indent: indent)
        }
    }

    static func plain(_ font: NSFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.labelColor]
    }
}

@MainActor
enum ChatMarkdown {
    struct Options {
        var style: MarkdownStyle
        /// Let tables grow past the column into the row's side space.
        var breakout: Bool
        var isExpanded: (String) -> Bool
        var toggle: (String) -> Void
        /// Content that arrived after the build (a rendered diagram):
        /// rebuild the document.
        var refresh: () -> Void = {}
    }

    private final class Blocks {
        let value: [MarkdownBlock]
        init(_ value: [MarkdownBlock]) { self.value = value }
    }

    private static let parsed: NSCache<NSString, Blocks> = {
        let cache = NSCache<NSString, Blocks>()
        cache.countLimit = 300
        return cache
    }()

    static func blocks(_ text: String) -> [MarkdownBlock] {
        if let hit = parsed.object(forKey: text as NSString) { return hit.value }
        let blocks = MarkdownParser.parse(text)
        parsed.setObject(Blocks(blocks), forKey: text as NSString)
        return blocks
    }

    /// `key` identifies the document, for the expansion state of its
    /// disclosures.
    static func node(_ text: String, options: Options, key: String) -> ChatNode {
        node(blocks(text), options: options, key: key)
    }

    static func node(_ blocks: [MarkdownBlock], options: Options, key: String) -> ChatNode {
        var builder = Builder(options: options, key: key)
        builder.add(blocks, Context(), firstGap: 0)
        builder.flush()
        return VStackNode(spaced: builder.items)
    }

    private struct Context {
        var indent: CGFloat = 0
        var quoteBars: [CGFloat] = []
        var secondary = false
    }

    @MainActor
    private struct Builder {
        let options: Options
        let key: String
        var items: [(ChatNode, CGFloat)] = []
        private var run: NSMutableAttributedString?
        private var runGap: CGFloat = 0
        private var detailsCount = 0
        private var diagramCount = 0

        init(options: Options, key: String) {
            self.options = options
            self.key = key
        }

        private var style: MarkdownStyle { options.style }

        mutating func flush() {
            if let run {
                items.append((TextNode(run), runGap))
                self.run = nil
            }
        }

        private mutating func block(_ node: ChatNode, gap: CGFloat, _ context: Context) {
            flush()
            let placed = context.indent > 0
                ? BoxNode(node, padding: NSEdgeInsets(top: 0, left: context.indent, bottom: 0, right: 0))
                : node
            items.append((placed, gap))
        }

        private mutating func paragraph(
            _ content: NSAttributedString,
            _ context: Context,
            gap: CGFloat,
            customize: (NSMutableParagraphStyle) -> Void = { _ in }
        ) {
            guard content.length > 0 else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            paragraph.firstLineHeadIndent = context.indent
            paragraph.headIndent = context.indent
            customize(paragraph)
            let piece = NSMutableAttributedString(attributedString: content)
            let range = NSRange(location: 0, length: piece.length)
            if let run {
                paragraph.paragraphSpacingBefore = gap
                // The break ends the previous paragraph: its layout, not its
                // inline styling (a code span's background would fill the
                // rest of the line).
                var attributes = run.attributes(at: run.length - 1, effectiveRange: nil)
                attributes[.backgroundColor] = nil
                attributes[.link] = nil
                attributes[.attachment] = nil
                run.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            piece.addAttribute(.paragraphStyle, value: paragraph, range: range)
            if !context.quoteBars.isEmpty {
                piece.addAttribute(.chatQuoteBars, value: context.quoteBars, range: range)
            }
            if let run {
                run.append(piece)
            } else {
                run = piece
                runGap = gap
            }
        }

        private func inline(_ source: String, _ context: Context, size: CGFloat? = nil, weight: NSFont.Weight? = nil) -> NSAttributedString {
            ChatInline.attributed(source, style: style, size: size ?? style.bodySize, weight: weight, secondary: context.secondary)
        }

        mutating func add(_ blocks: [MarkdownBlock], _ context: Context, firstGap: CGFloat) {
            for (index, block) in blocks.enumerated() {
                let gap = index == 0 ? firstGap : style.blockSpacing
                switch block {
                case let .paragraph(text):
                    paragraph(inline(text, context), context, gap: gap)

                case let .heading(level, text):
                    let size = style.headingSize(level)
                    paragraph(inline(text, context, size: size, weight: .semibold), context, gap: gap + (level <= 2 ? 2 : 0))

                case let .code(language, text, closed):
                    self.block(codeBlock(language: language, code: text, closed: closed, context), gap: gap, context)

                case let .math(tex):
                    self.block(mathNode(tex, context), gap: gap, context)

                case let .quote(inner):
                    var quoted = context
                    quoted.quoteBars.append(context.indent)
                    quoted.indent += 11
                    quoted.secondary = true
                    add(inner, quoted, firstGap: gap)

                case let .list(list):
                    addList(list, context, gap: gap)

                case let .table(table):
                    self.block(ChatTableNode(table: table, style: style, breakout: options.breakout), gap: gap, context)

                case .rule:
                    self.block(BoxNode(FillNode(height: 1, color: .separatorColor), padding: NSEdgeInsets(v: 2)), gap: gap, context)

                case let .details(summary, inner):
                    let id = "\(key).d\(detailsCount)"
                    detailsCount += 1
                    self.block(detailsNode(summary: summary, blocks: inner, id: id), gap: gap, context)
                }
            }
        }

        private mutating func addList(_ list: MarkdownList, _ context: Context, gap: CGFloat) {
            // Right-aligned markers end at `markerWidth`; one wider than
            // that would push the text past its tab stop onto a new line.
            let isTaskList = list.items.contains { $0.checked != nil }
            let markerWidth: CGFloat = list.ordered || isTaskList ? 16 : 10
            let base = context.indent + 2
            let contentX = base + markerWidth + 6
            var inner = context
            inner.indent = contentX
            let tabs = [
                NSTextTab(textAlignment: .right, location: base + markerWidth),
                NSTextTab(textAlignment: .left, location: contentX),
            ]
            let bodyFont = ChatFonts.text(size: style.bodySize, family: style.fontFamily)
            for (index, item) in list.items.enumerated() {
                let line = NSMutableAttributedString(string: "\t", attributes: [.font: bodyFont])
                line.append(marker(list: list, item: item, index: index, font: bodyFont))
                line.append(NSAttributedString(string: "\t", attributes: [.font: bodyFont]))
                var rest = item.blocks[...]
                if case let .paragraph(text)? = item.blocks.first {
                    line.append(inline(text, inner))
                    rest = item.blocks.dropFirst()
                }
                paragraph(line, inner, gap: index == 0 ? gap : 3) { paragraph in
                    paragraph.firstLineHeadIndent = base
                    paragraph.tabStops = tabs
                }
                add(Array(rest), inner, firstGap: style.blockSpacing)
            }
        }

        private func marker(list: MarkdownList, item: MarkdownList.Item, index: Int, font: NSFont) -> NSAttributedString {
            if let checked = item.checked {
                let color: NSColor = checked ? .controlAccentColor : .secondaryLabelColor
                let config = NSImage.SymbolConfiguration(pointSize: style.bodySize - 1, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
                guard let image = NSImage(systemSymbolName: checked ? "checkmark.square.fill" : "square", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) else { return NSAttributedString(string: checked ? "☑" : "☐") }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(x: 0, y: ((font.capHeight - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
                return NSAttributedString(attachment: attachment)
            }
            if list.ordered {
                return NSAttributedString(string: "\(list.start + index).", attributes: [
                    .font: ChatFonts.code(size: style.bodySize, style: style),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            }
            return NSAttributedString(string: "•", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }

        private mutating func codeBlock(language: String?, code: String, closed: Bool, _ context: Context) -> ChatNode {
            switch ChatFence(language) {
            case .mermaid:
                return mermaidNode(code, closed: closed)
            case .math where closed:
                return mathNode(code, context)
            default:
                return codeNode(language: language, code: code, closed: closed)
            }
        }

        /// Fenced code: syntax-highlighted when the language is known, tinted
        /// line by line when it's a diff.
        private func codeNode(language: String?, code: String, closed: Bool = true, note: String? = nil, action: (String, () -> Void)? = nil) -> ChatNode {
            var parts: [ChatNode] = []
            if let header = codeHeader(language: language, note: note, action: action) {
                parts.append(header)
            }
            let font = ChatFonts.code(size: style.codeSize, style: style)
            switch ChatFence(language) {
            case .diff:
                // Tints run edge to edge, so the padding lives in the text.
                let text = ChatCode.diff(code, font: font, indent: 8, store: closed)
                parts.append(BoxNode(
                    HScrollNode(TextNode(text, wraps: false, trailingPad: 8), fillViewport: true),
                    padding: NSEdgeInsets(top: parts.isEmpty ? 6 : 3, left: 0, bottom: 6, right: 0)
                ))
            case let .highlighted(syntax):
                parts.append(scrollingCode(ChatCode.highlighted(code, language: syntax, font: font, store: closed)))
            default:
                parts.append(scrollingCode(NSAttributedString(string: code, attributes: ChatCode.plain(font))))
            }
            return codeFrame(parts)
        }

        /// Scrolls rather than wraps: a wrapped code line loses its
        /// indentation cues.
        private func scrollingCode(_ text: NSAttributedString) -> ChatNode {
            HScrollNode(BoxNode(TextNode(text, wraps: false), padding: NSEdgeInsets(h: 8, v: 6), hug: true))
        }

        private func codeFrame(_ parts: [ChatNode]) -> ChatNode {
            BoxNode(VStackNode(parts), fill: .secondary(0.10), border: .secondary(0.18), borderWidth: 0.5, radius: 5)
        }

        /// The language label, an optional note after it, and an optional
        /// action at the trailing edge. Nil when there's none of the three.
        private func codeHeader(language: String?, note: String?, action: (String, () -> Void)?) -> ChatNode? {
            var label = ChatFence.label(language)
            if let note { label += label.isEmpty ? note : " · \(note)" }
            guard !label.isEmpty || action != nil else { return nil }
            var items: [ChatNode] = [CaptionNode(label, font: MonoFont.ns(size: 9, weight: .medium, family: style.monoFamily))]
            if let (title, perform) = action {
                items.append(ClickNode(
                    LabelNode(title, font: .systemFont(ofSize: 10, weight: .medium), color: .linkColor),
                    pointingCursor: true,
                    action: perform
                ))
            }
            return BoxNode(
                HStackNode(items, spacing: 8, flexible: [0]),
                padding: NSEdgeInsets(top: 5, left: 8, bottom: 0, right: 8)
            )
        }

        /// A mermaid fence as its diagram, once rendered. Until then, and
        /// when it won't render, the source.
        private mutating func mermaidNode(_ code: String, closed: Bool) -> ChatNode {
            let id = "\(key).m\(diagramCount)"
            diagramCount += 1
            // A fence still streaming in isn't a whole diagram yet.
            guard closed, !code.isEmpty else { return codeNode(language: "mermaid", code: code, closed: closed) }
            let toggle = options.toggle
            if options.isExpanded(id) {
                return codeNode(language: "mermaid", code: code, action: ("Show diagram", { toggle(id) }))
            }
            let renderer = MermaidRenderer.shared
            switch renderer.anyResult(code) {
            case let .diagram(_, natural)?:
                let header = codeHeader(language: "mermaid", note: nil, action: ("Show source", { toggle(id) }))!
                return codeFrame([header, BoxNode(MermaidNode(source: code, natural: natural), padding: NSEdgeInsets(h: 12, v: 10))])
            case let .failed(message)?:
                let firstLine = message.split(separator: "\n").first.map(String.init) ?? message
                return codeNode(language: "mermaid", code: code, note: "couldn't render: \(firstLine)")
            case nil:
                renderer.request(code, dark: NSApp.effectiveAppearance.isDark, owner: id, done: options.refresh)
                return codeNode(language: "mermaid", code: code, note: "rendering…")
            }
        }

        /// Display math, centered, scrolling sideways when it's too wide.
        /// TeX that won't typeset shows as its source.
        private func mathNode(_ tex: String, _ context: Context) -> ChatNode {
            let size = ChatMath.fontSize(forText: style.bodySize)
            guard let math = ChatMath.typeset(tex, size: size, display: true) else {
                return codeNode(language: "math", code: tex)
            }
            return HScrollNode(MathBlockNode(math: math, secondary: context.secondary), fillViewport: true)
        }

        private func detailsNode(summary: String, blocks: [MarkdownBlock], id: String) -> ChatNode {
            let expanded = options.isExpanded(id)
            let toggle = options.toggle
            let header = ClickNode(HStackNode([
                BoxNode(SymbolNode(expanded ? "chevron.down" : "chevron.right", size: style.bodySize - 3), width: style.bodySize),
                LabelNode(ChatInline.attributed(summary, style: style, size: style.bodySize, weight: .medium)),
            ], spacing: 5, flexible: [1])) { toggle(id) }
            var parts: [ChatNode] = [header]
            if expanded {
                parts.append(BoxNode(
                    ChatMarkdown.node(blocks, options: options, key: id),
                    padding: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 0)
                ))
            }
            return VStackNode(parts, spacing: 6)
        }
    }
}

// MARK: - Tables

/// A table at its natural width. With breakout it may grow past the column
/// up to the row's edges, centred on the column; wider than that it
/// scrolls sideways.
final class ChatTableNode: ChatNode {
    private let grid: TableGridNode
    private let scroll: HScrollNode
    private let breakout: Bool
    /// Breathing room between a broken-out table and the row's edges. Kept
    /// inside the scroller, so a scrolled table runs right up to them.
    static let margin: CGFloat = 24

    init(table: MarkdownTable, style: MarkdownStyle, breakout: Bool) {
        grid = TableGridNode(table: table, style: style)
        scroll = HScrollNode(grid, margin: breakout ? Self.margin : 0)
        self.breakout = breakout
    }

    override var children: [ChatNode] { [scroll] }

    override func measure(_ width: CGFloat) -> CGSize {
        CGSize(width: width, height: grid.size(for: ChatNode.unbounded).height)
    }

    override func layout(_ size: CGSize, breakout limits: ChatBreakout) -> [ChatChildFrame] {
        guard breakout else { return [ChatChildFrame(rect: CGRect(origin: .zero, size: size))] }
        let natural = grid.size(for: ChatNode.unbounded).width
        let available = size.width + limits.leading + limits.trailing
        let width = min(max(natural, size.width) + Self.margin * 2, available)
        var x = (size.width - width) / 2
        x = min(max(x, -limits.leading), size.width + limits.trailing - width)
        return [ChatChildFrame(rect: CGRect(x: x.rounded(), y: 0, width: width, height: size.height))]
    }
}

/// Selectable, wrapping text for a table cell.
final class ChatCellField: NSTextField {
    static func make() -> ChatCellField {
        let field = ChatCellField(frame: .zero)
        field.isEditable = false
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.isBordered = false
        field.drawsBackground = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        return field
    }

    private static let measuring = ChatCellField.make()

    static func size(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        measuring.attributedStringValue = string
        let size = measuring.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: ChatNode.unbounded)) ?? .zero
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

/// Rounded, bordered grid: shaded header row, a hairline between rows,
/// roomy cells.
final class TableGridNode: ChatNode {
    struct Metrics {
        var cells: [[NSAttributedString]]
        var cellSizes: [[CGSize]]
        var columnWidths: [CGFloat]
        var rowHeights: [CGFloat]
        var size: CGSize
    }

    static let cellMaxWidth: CGFloat = 480
    static let cellPadding = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    let table: MarkdownTable
    let style: MarkdownStyle
    private var cachedMetrics: Metrics?

    init(table: MarkdownTable, style: MarkdownStyle) {
        self.table = table
        self.style = style
    }

    var metrics: Metrics {
        if let cachedMetrics { return cachedMetrics }
        let size = style.tableBodySize ?? style.bodySize
        let columns = max(table.columnCount, 1)
        func cell(_ source: String, column: Int, header: Bool) -> NSAttributedString {
            let text = NSMutableAttributedString(attributedString: ChatInline.attributed(
                source, style: style, size: size, weight: header ? .semibold : nil
            ))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            paragraph.alignment = column < table.alignments.count ? table.alignments[column].nsAlignment : .left
            text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
            return text
        }
        var cells: [[NSAttributedString]] = [table.header.enumerated().map { cell($1, column: $0, header: true) }]
        for row in table.rows {
            cells.append(row.prefix(columns).enumerated().map { cell($1, column: $0, header: false) })
        }
        var widths = Array(repeating: CGFloat(0), count: columns)
        var sizes: [[CGSize]] = []
        for row in cells {
            var rowSizes: [CGSize] = []
            for (column, text) in row.enumerated() {
                let natural = ChatCellField.size(text, width: ChatNode.unbounded)
                let size = natural.width > Self.cellMaxWidth
                    ? CGSize(width: Self.cellMaxWidth, height: ChatCellField.size(text, width: Self.cellMaxWidth).height)
                    : natural
                rowSizes.append(size)
                widths[column] = max(widths[column], size.width)
            }
            sizes.append(rowSizes)
        }
        let vertical = Self.cellPadding.top + Self.cellPadding.bottom
        let heights = sizes.map { row in (row.map(\.height).max() ?? 0) + vertical }
        let horizontal = Self.cellPadding.left + Self.cellPadding.right
        let totalWidth = widths.reduce(0) { $0 + $1 + horizontal } + 2
        let totalHeight = heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) + 2
        let metrics = Metrics(cells: cells, cellSizes: sizes, columnWidths: widths, rowHeights: heights, size: CGSize(width: totalWidth, height: totalHeight))
        cachedMetrics = metrics
        return metrics
    }

    override func measure(_ width: CGFloat) -> CGSize { metrics.size }
    override var viewType: NSView.Type { ChatTableGridView.self }
    override func makeView() -> NSView { ChatTableGridView() }
    override func configure(_ view: NSView, size: CGSize) {
        (view as? ChatTableGridView)?.apply(metrics)
    }
}

final class ChatTableGridView: NSView {
    private let frameView = ChatContainerView()
    private let headerFill = ChatContainerView()
    private var fields: [ChatCellField] = []
    private var dividers: [ChatContainerView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(frameView)
        frameView.addSubview(headerFill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func apply(_ metrics: TableGridNode.Metrics) {
        let box = bounds.insetBy(dx: 1, dy: 1)
        frameView.frame = box
        frameView.setStyle(fill: nil, border: .secondary(0.22), borderWidth: 1, cornerRadius: 8, clips: true)
        headerFill.setStyle(fill: .secondary(0.08))
        headerFill.frame = CGRect(x: 0, y: 0, width: box.width, height: metrics.rowHeights.first ?? 0)

        let padding = TableGridNode.cellPadding
        var fieldIndex = 0
        var dividerIndex = 0
        var y: CGFloat = 0
        for (row, cells) in metrics.cells.enumerated() {
            if row > 0 {
                let divider = dividerIndex < dividers.count ? dividers[dividerIndex] : {
                    let view = ChatContainerView()
                    dividers.append(view)
                    frameView.addSubview(view)
                    return view
                }()
                divider.setStyle(fill: .separatorColor)
                divider.isHidden = false
                divider.frame = CGRect(x: 0, y: y, width: box.width, height: 1)
                dividerIndex += 1
                y += 1
            }
            var x: CGFloat = 0
            for (column, text) in cells.enumerated() {
                let field = fieldIndex < fields.count ? fields[fieldIndex] : {
                    let field = ChatCellField.make()
                    fields.append(field)
                    frameView.addSubview(field)
                    return field
                }()
                if field.attributedStringValue != text { field.attributedStringValue = text }
                field.isHidden = false
                let width = metrics.columnWidths[column]
                field.frame = CGRect(x: x + padding.left, y: y + padding.top, width: width, height: metrics.cellSizes[row][column].height)
                x += width + padding.left + padding.right
                fieldIndex += 1
            }
            y += metrics.rowHeights[row]
        }
        for field in fields[fieldIndex...] { field.isHidden = true }
        for divider in dividers[dividerIndex...] { divider.isHidden = true }
    }
}

extension MarkdownTable.Align {
    var nsAlignment: NSTextAlignment {
        switch self {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
        }
    }
}
#endif
