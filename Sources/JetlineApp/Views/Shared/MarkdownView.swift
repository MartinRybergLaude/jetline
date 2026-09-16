import SwiftUI
import AppKit

/// Type sizes for rendered markdown. Kept as explicit point sizes rather
/// than semantic `Font`s because headings need to scale relative to the
/// body size, and the inspector runs smaller than system body text.
struct MarkdownStyle: Hashable {
    var bodySize: CGFloat = 12
    var codeSize: CGFloat = 11
    /// Vertical gap between sibling blocks.
    var blockSpacing: CGFloat = 8

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
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, style: style)
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
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: item, at: index)
                        .frame(minWidth: list.ordered ? 16 : 10, alignment: .trailing)
                    MarkdownView(blocks: item.blocks, style: style)
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
                .font(.system(size: style.bodySize))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tables

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let style: MarkdownStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { index, cell in
                        cellText(cell, column: index, bold: true)
                    }
                }
                Divider().gridCellColumns(max(table.columnCount, 1))
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellText(cell, column: index, bold: false)
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func cellText(_ source: String, column: Int, bold: Bool) -> some View {
        Text(MarkdownInlineCache.attributed(
            source,
            style: style,
            size: style.bodySize,
            weight: bold ? .semibold : nil
        ))
        .multilineTextAlignment(alignment(column))
        .frame(maxWidth: 280, alignment: frameAlignment(column))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ column: Int) -> TextAlignment {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .leading {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
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
        return cache
    }()

    static func attributed(
        _ source: String,
        style: MarkdownStyle,
        size: CGFloat,
        weight: Font.Weight?
    ) -> AttributedString {
        let key = "\(size)|\(style.codeSize)|\(weight.map(String.init(describing:)) ?? "-")|\(source)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let value = render(source, style: style, size: size, weight: weight)
        cache.setObject(Box(value), forKey: key)
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
                : .system(size: size)
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
