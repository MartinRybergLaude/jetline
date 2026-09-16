import Foundation

/// Block-level structure of a GitHub-flavored markdown document.
///
/// Inline spans (emphasis, code spans, links) are *not* decomposed here —
/// each case carries its inline source verbatim and `MarkdownInline` turns
/// that into an `AttributedString` at render time. Splitting the two keeps
/// this parser small: block structure is line-oriented and needs a real
/// state machine, while inline parsing is already solved by Foundation's
/// `AttributedString(markdown:)`.
enum MarkdownBlock: Hashable, Sendable {
    /// Inline source of one paragraph. Soft line breaks are preserved.
    case paragraph(String)
    case heading(level: Int, text: String)
    /// Fenced code. `language` is the fence info string, lowercased, or nil.
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case rule
    /// `<details><summary>…</summary>…</details>`. Bot reviewers (Copilot,
    /// coverage bots) lean on this heavily, and flattening it would dump
    /// hundreds of lines of collapsed content into the panel.
    case details(summary: String, blocks: [MarkdownBlock])
}

struct MarkdownList: Hashable, Sendable {
    struct Item: Hashable, Sendable {
        /// `nil` for a plain bullet; `true`/`false` for a `- [x]` / `- [ ]`
        /// task item.
        var checked: Bool?
        var blocks: [MarkdownBlock]
    }

    var ordered: Bool
    /// First number of an ordered list (`3.` starts at 3, like GitHub).
    var start: Int
    var items: [Item]
}

struct MarkdownTable: Hashable, Sendable {
    enum Align: Hashable, Sendable {
        case leading, center, trailing
    }

    var header: [String]
    /// One entry per column, derived from the delimiter row's colons.
    var alignments: [Align]
    var rows: [[String]]

    var columnCount: Int { header.count }
}
