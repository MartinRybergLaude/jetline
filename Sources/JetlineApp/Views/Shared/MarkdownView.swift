import SwiftUI

/// Type sizes for rendered markdown. Kept as explicit point sizes rather
/// than semantic `Font`s because headings need to scale relative to the
/// body size, and the inspector runs smaller than system body text.
struct MarkdownStyle: Hashable {
    var bodySize: CGFloat = 12
    var codeSize: CGFloat = 11
    /// Vertical gap between sibling blocks.
    var blockSpacing: CGFloat = 8
    /// Family for non-code text; `nil` → system font.
    var fontFamily: String?
    /// Table text size; `nil` → `bodySize`.
    var tableBodySize: CGFloat?
    /// Extra leading between wrapped lines.
    var lineSpacing: CGFloat = 0
    /// Airy, striped tables for reading room (the chat) rather than the
    /// inspector's dense boxed ones.
    var spaciousTables = false

    static let comment = MarkdownStyle()
    /// Slightly tighter, for the quoted body of an inline review thread.
    static let compact = MarkdownStyle(bodySize: 11.5, codeSize: 10.5, blockSpacing: 6)
}

/// Renders parsed markdown blocks as native SwiftUI views.
///
/// Native rather than a `WKWebView` over GitHub's `bodyHTML`: text stays
/// selectable and searchable alongside the rest of the inspector, light and
/// dark mode come for free, and a web view per comment would be far heavier
/// than these are.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var style: MarkdownStyle = .comment

    var body: some View {
        VStack(alignment: .leading, spacing: style.blockSpacing) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index], style: style)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let style: MarkdownStyle

    var body: some View {
        switch block {
        case let .paragraph(text):
            inline(text)

        case let .heading(level, text):
            inline(text, size: Self.headingSize(level, base: style.bodySize), weight: .semibold)
                .padding(.top, level <= 2 ? 2 : 0)

        case let .code(language, text):
            CodeBlockView(language: language, code: text, style: style)

        case let .quote(blocks):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 3)
                MarkdownView(blocks: blocks, style: style)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .list(list):
            MarkdownListView(list: list, style: style)

        case let .table(table):
            MarkdownTableView(table: table, style: style)

        case .rule:
            Divider().padding(.vertical, 2)

        case let .details(summary, blocks):
            MarkdownDetailsView(summary: summary, blocks: blocks, style: style)
        }
    }

    private func inline(_ source: String, size: CGFloat? = nil, weight: Font.Weight? = nil) -> some View {
        Text(MarkdownInlineCache.attributed(
            source,
            style: style,
            size: size ?? style.bodySize,
            weight: weight
        ))
        .lineSpacing(style.lineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// GitHub's own heading ramp, rebased on the panel's body size. h5/h6 sit
    /// below body size, which is what makes deep headings read as labels.
    private static func headingSize(_ level: Int, base: CGFloat) -> CGFloat {
        switch level {
        case 1:  return base + 6
        case 2:  return base + 4
        case 3:  return base + 2
        case 4:  return base + 1
        case 5:  return base
        default: return base - 1
        }
    }
}

// MARK: - Code

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 5)
            }
            // Horizontal scrolling rather than wrapping: a wrapped code line
            // loses its indentation cues, which is exactly what you're
            // reading code in a review comment for.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: style.codeSize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }
}

// MARK: - Lists

private struct MarkdownListView: View {
    let list: MarkdownList
    let style: MarkdownStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: list.items[index], at: index)
                        .frame(minWidth: list.ordered ? 16 : 10, alignment: .trailing)
                    MarkdownView(blocks: list.items[index].blocks, style: style)
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func marker(for item: MarkdownList.Item, at index: Int) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: style.bodySize - 1))
                .foregroundStyle(checked ? Color.accentColor : .secondary)
        } else if list.ordered {
            Text("\(list.start + index).")
                .font(.system(size: style.bodySize, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text("•")
                .font(.chat(size: style.bodySize, family: style.fontFamily))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tables

extension EnvironmentValues {
    /// Width a table may grow to beyond its column, centred on it. `nil`
    /// keeps tables within the column. The chat sets this so tables can use
    /// the space beside its narrow reading column.
    @Entry var markdownTableBreakoutWidth: CGFloat?
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let style: MarkdownStyle
    @Environment(\.markdownTableBreakoutWidth) private var breakoutWidth
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        TableBreakoutLayout(contentWidth: contentWidth, limit: breakoutWidth) {
            scroller
        }
    }

    @ViewBuilder
    private var scroller: some View {
        if style.spaciousTables {
            spaciousScroller
        } else {
            compactScroller
        }
    }

    private var compactScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { index in
                        cellText(table.header[index], column: index, bold: true)
                    }
                }
                Divider().gridCellColumns(max(table.columnCount, 1))
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { index in
                            cellText(table.rows[row][index], column: index, bold: false)
                        }
                    }
                }
            }
            .padding(8)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    /// Uppercase tracked header, generous cell padding, alternate rows on a
    /// rounded stripe, row labels in the first column bold. No box around it.
    private var spaciousScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { index in
                        spaciousCell(column: index, stripe: false) {
                            Text(Self.uppercased(MarkdownInlineCache.attributed(
                                table.header[index],
                                style: style,
                                size: tableSize - 3,
                                weight: .semibold
                            )))
                            .tracking(0.6)
                        }
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { index in
                            spaciousCell(column: index, stripe: row % 2 == 0) {
                                Text(MarkdownInlineCache.attributed(
                                    table.rows[row][index],
                                    style: style,
                                    size: tableSize,
                                    weight: index == 0 ? .semibold : nil
                                ))
                                .lineSpacing(style.lineSpacing)
                            }
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        }
    }

    private var tableSize: CGFloat { style.tableBodySize ?? style.bodySize }

    private func spaciousCell(column: Int, stripe: Bool, @ViewBuilder content: () -> some View) -> some View {
        let align = table.alignments[column]
        let radius: CGFloat = 8
        let first = column == 0
        let last = column == table.columnCount - 1
        return content()
            .multilineTextAlignment(align.textAlignment)
            .modifier(CappedWidth(maxWidth: 320))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: align.frameAlignment.horizontal, vertical: .center))
            .background {
                if stripe {
                    UnevenRoundedRectangle(
                        topLeadingRadius: first ? radius : 0,
                        bottomLeadingRadius: first ? radius : 0,
                        bottomTrailingRadius: last ? radius : 0,
                        topTrailingRadius: last ? radius : 0
                    )
                    .fill(Color.secondary.opacity(0.07))
                }
            }
            .gridColumnAlignment(align.frameAlignment.horizontal)
    }

    /// Uppercases everything but code spans, which would change meaning.
    private static func uppercased(_ text: AttributedString) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result += text[run.range]
            } else {
                result += AttributedString(String(text[run.range].characters).uppercased(), attributes: run.attributes)
            }
        }
        return result
    }

    private func cellText(_ source: String, column: Int, bold: Bool) -> some View {
        // `takeTable` pads every row to the header width, so the column index
        // is always in range.
        let align = table.alignments[column]
        return Text(MarkdownInlineCache.attributed(
            source,
            style: style,
            size: tableSize,
            weight: bold ? .semibold : nil
        ))
        .multilineTextAlignment(align.textAlignment)
        .modifier(CappedWidth(maxWidth: 280))
        .gridColumnAlignment(align.frameAlignment.horizontal)
    }
}

/// Takes the column's width, but lays the table out at its natural width
/// up to `limit`, centred on the column and overhanging it on both sides.
/// Wider than that, the table scrolls horizontally.
private struct TableBreakoutLayout: Layout {
    let contentWidth: CGFloat
    let limit: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = proposal.width ?? contentWidth
        let height = subview.sizeThatFits(ProposedViewSize(width: layoutWidth(column: width), height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = layoutWidth(column: bounds.width)
        subviews.first?.place(
            at: CGPoint(x: bounds.midX - width / 2, y: bounds.minY),
            proposal: ProposedViewSize(width: width, height: nil)
        )
    }

    private func layoutWidth(column: CGFloat) -> CGFloat {
        guard let limit, limit > column else { return column }
        return min(max(contentWidth, column), limit)
    }
}

/// Sizes a cell to its natural width up to `maxWidth`, then measures its
/// height *at that width*. `.frame(maxWidth:)` can't do this inside the
/// horizontal scroll view: the scroll view proposes no width, so text
/// reports its one-line height, then wraps at the cap and overflows into
/// the rows below.
private struct CappedWidth: ViewModifier {
    let maxWidth: CGFloat

    func body(content: Content) -> some View {
        CappedWidthLayout(maxWidth: maxWidth) { content }
    }
}

private struct CappedWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(subview.sizeThatFits(.unspecified).width, maxWidth)
        let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

// MARK: - Disclosure

private struct MarkdownDetailsView: View {
    let summary: String
    let blocks: [MarkdownBlock]
    let style: MarkdownStyle
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: style.bodySize - 3))
                        .foregroundStyle(.secondary)
                    Text(MarkdownInlineCache.attributed(
                        summary,
                        style: style,
                        size: style.bodySize,
                        weight: .medium
                    ))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                MarkdownView(blocks: blocks, style: style)
                    .padding(.leading, 14)
            }
        }
    }
}

// MARK: - Inline styling

/// Memoizes `source → styled AttributedString`.
///
/// Inline parsing walks the string several times (markdown, HTML, entities,
/// link detection) and comment bodies are re-rendered on every enclosing
/// view update — scrolling the panel would otherwise re-parse every visible
/// comment each frame. `NSCache` keeps the cost bounded without a manual
/// eviction policy.
@MainActor
enum MarkdownInlineCache {
    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 2000
        // Also bound by bytes: bot reviews dump tens of KB of `<details>`
        // content, and a count-only limit would let the cache park that
        // indefinitely in a process-lifetime static.
        cache.totalCostLimit = 4 << 20
        return cache
    }()

    static func attributed(
        _ source: String,
        style: MarkdownStyle,
        size: CGFloat,
        weight: Font.Weight?
    ) -> AttributedString {
        // `weight` is tagged by hand rather than interpolated: `Font.Weight`
        // isn't `CustomStringConvertible`, so `String(describing:)` falls back
        // to reflection and dominates the cost of a cache hit.
        let key = "\(size)|\(style.codeSize)|\(style.fontFamily ?? "")|\(weight == nil ? 0 : 1)|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = render(source, style: style, size: size, weight: weight)
        cache.setObject(Box(value), forKey: key, cost: source.utf8.count)
        return value
    }

    /// Resolves Foundation's `inlinePresentationIntent` into concrete SwiftUI
    /// attributes. Doing it explicitly rather than relying on `Text`'s own
    /// interpretation keeps bold/italic/strikethrough composable with the
    /// per-run monospaced font that code spans need.
    private static func render(
        _ source: String,
        style: MarkdownStyle,
        size: CGFloat,
        weight: Font.Weight?
    ) -> AttributedString {
        var attributed = MarkdownInline.parse(source)

        // Snapshot the ranges before mutating: attribute writes invalidate
        // the run sequence being iterated.
        let runs = attributed.runs.map { ($0.range, $0.inlinePresentationIntent ?? [], $0.link) }
        for (range, intent, link) in runs {
            var font: Font = intent.contains(.code)
                ? .system(size: style.codeSize, design: .monospaced)
                : .chat(size: size, family: style.fontFamily)
            if let weight { font = font.weight(weight) }
            if intent.contains(.stronglyEmphasized) { font = font.bold() }
            if intent.contains(.emphasized) { font = font.italic() }
            attributed[range].font = font

            if intent.contains(.strikethrough) {
                attributed[range].strikethroughStyle = .single
            }
            if intent.contains(.code) {
                attributed[range].backgroundColor = Color.secondary.opacity(0.18)
            }
            if link != nil {
                attributed[range].foregroundColor = .accentColor
                attributed[range].underlineStyle = .single
            }
        }
        return attributed
    }
}

extension MarkdownTable.Align {
    var textAlignment: TextAlignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }
}
