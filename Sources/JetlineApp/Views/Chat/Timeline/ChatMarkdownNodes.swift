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
        if let family, let custom = NSFontManager.shared.font(withFamily: family, traits: [], weight: managerWeight(weight), size: size) {
            base = custom
        } else {
            base = .systemFont(ofSize: size, weight: weight ?? .regular)
        }
        return styled(base, bold: bold, italic: italic)
    }

    static func mono(size: CGFloat, weight: NSFont.Weight? = nil, bold: Bool = false, italic: Bool = false) -> NSFont {
        styled(.monospacedSystemFont(ofSize: size, weight: weight ?? .regular), bold: bold, italic: italic)
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// `NSFontManager`'s 0–15 weight scale.
    private static func managerWeight(_ weight: NSFont.Weight?) -> Int {
        switch weight {
        case .medium?: return 6
        case .semibold?: return 8
        case .bold?, .heavy?, .black?: return 9
        default: return 5
        }
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font))
    }
}

/// Memoizes inline markdown → styled `NSAttributedString`, like
/// `MarkdownInlineCache` does for the SwiftUI renderer.
@MainActor
enum ChatInline {
    private final class Box {
        let value: NSAttributedString
        init(_ value: NSAttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
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
        let key = "\(size)|\(style.codeSize)|\(style.fontFamily ?? "")|\(weight?.rawValue ?? 0)|\(secondary ? 1 : 0)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = render(source, style: style, size: size, weight: weight, secondary: secondary)
        cache.setObject(Box(value), forKey: key, cost: source.utf8.count)
        return value
    }

    private static func render(_ source: String, style: MarkdownStyle, size: CGFloat, weight: NSFont.Weight?, secondary: Bool) -> NSAttributedString {
        let parsed = MarkdownInline.parse(source)
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
                attributes[.font] = ChatFonts.mono(size: style.codeSize, weight: weight, bold: bold, italic: italic)
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
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        return out
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

    static func headingSize(_ level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1: return base + 6
        case 2: return base + 4
        case 3: return base + 2
        case 4: return base + 1
        case 5: return base
        default: return base - 1
        }
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
                    let size = ChatMarkdown.headingSize(level, base: style.bodySize)
                    paragraph(inline(text, context, size: size, weight: .semibold), context, gap: gap + (level <= 2 ? 2 : 0))

                case let .code(language, text):
                    self.block(codeNode(language: language, code: text), gap: gap, context)

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
                    .font: ChatFonts.mono(size: style.bodySize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
            }
            return NSAttributedString(string: "•", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }

        private func codeNode(language: String?, code: String) -> ChatNode {
            var parts: [ChatNode] = []
            if let language, !language.isEmpty {
                parts.append(BoxNode(
                    LabelNode(language, font: .monospacedSystemFont(ofSize: 9, weight: .medium), color: .secondaryLabelColor),
                    padding: NSEdgeInsets(top: 5, left: 8, bottom: 0, right: 8)
                ))
            }
            let text = NSAttributedString(string: code, attributes: [
                .font: ChatFonts.mono(size: style.codeSize),
                .foregroundColor: NSColor.labelColor,
            ])
            // Scrolls rather than wraps: a wrapped code line loses its
            // indentation cues.
            parts.append(HScrollNode(BoxNode(TextNode(text, wraps: false), padding: NSEdgeInsets(h: 8, v: 6), hug: true)))
            return BoxNode(VStackNode(parts), fill: .secondary(0.10), border: .secondary(0.18), borderWidth: 0.5, radius: 5)
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
