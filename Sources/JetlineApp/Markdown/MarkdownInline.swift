import Foundation

/// Inline-span rendering for a single markdown block's source text.
///
/// Foundation's `AttributedString(markdown:)` already handles emphasis,
/// code spans, links and HTML entities, so this only adds what it doesn't:
/// GitHub's raw HTML passthrough, and autolinking of bare URLs (GFM does it,
/// CommonMark doesn't).
///
/// The output carries Foundation attributes only — `inlinePresentationIntent`
/// and `.link`. Fonts and colors are applied by the view layer, which is the
/// only place that knows the ambient text size.
enum MarkdownInline {
    static func parse(_ source: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: source,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(source)

        attributed = cleaningHTML(attributed)
        addAutolinks(to: &attributed)
        return attributed
    }

    // MARK: - Raw HTML

    /// GitHub renders a documented set of HTML tags inside comments. We
    /// can't render them, but leaving the raw markup in place is worse than
    /// dropping it, so tags from that set are removed and their text kept.
    ///
    /// The allowlist matters: a blanket `<[^>]+>` strip would eat generic
    /// parameters like `Array<Int>` out of prose. Code spans are skipped
    /// wholesale for the same reason.
    private static let knownTags: Set<String> = [
        "a", "abbr", "b", "blockquote", "br", "center", "cite", "code", "dd",
        "del", "details", "div", "dl", "dt", "em", "font", "g-emoji", "h1",
        "h2", "h3", "h4", "h5", "h6", "hr", "i", "img", "ins", "kbd", "li",
        "ol", "p", "picture", "pre", "q", "s", "samp", "small", "source",
        "span", "strike", "strong", "sub", "summary", "sup", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul", "var", "video"
    ]

    private static func cleaningHTML(_ input: AttributedString) -> AttributedString {
        var out = AttributedString()
        for run in input.runs {
            let slice = input[run.range]
            if run.inlinePresentationIntent?.contains(.code) == true {
                out.append(AttributedString(slice))
                continue
            }
            var replacement = AttributedString(stripTags(String(slice.characters)))
            replacement.mergeAttributes(run.attributes)
            out.append(replacement)
        }
        return out
    }

    private static func stripTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "<" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            guard let tag = tagRange(in: text, from: index) else {
                out.append("<")
                index = text.index(after: index)
                continue
            }
            // `<br>` is the one tag whose whole purpose is the line break it
            // produces; everything else just disappears.
            if tag.name == "br" { out.append("\n") }
            index = tag.end
        }
        return out
    }

    /// Parses one `<tag …>` / `</tag>` starting at `start`, honoring quoted
    /// attribute values so a `>` inside `alt="a > b"` doesn't end it early.
    private static func tagRange(
        in text: String,
        from start: String.Index
    ) -> (name: String, end: String.Index)? {
        var index = text.index(after: start)
        if index < text.endIndex, text[index] == "/" { index = text.index(after: index) }

        var name = ""
        while index < text.endIndex, text[index].isLetter || text[index].isNumber || text[index] == "-" {
            name.append(text[index])
            index = text.index(after: index)
        }
        guard knownTags.contains(name.lowercased()) else { return nil }

        var quote: Character?
        while index < text.endIndex {
            let ch = text[index]
            index = text.index(after: index)
            if let open = quote {
                if ch == open { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return (name.lowercased(), index)
            }
        }
        return nil
    }

    // MARK: - Autolinks

    /// Hoisted: constructing a detector per comment body is wasteful, and
    /// `NSDataDetector` is `Sendable`.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// GFM turns bare URLs into links; CommonMark (and therefore Foundation's
    /// parser) leaves them as text. Runs that are already links or code are
    /// left alone.
    private static func addAutolinks(to attributed: inout AttributedString) {
        guard let detector = linkDetector else { return }
        let plain = String(attributed.characters)
        guard plain.contains("://") else { return }

        let matches = detector.matches(
            in: plain,
            range: NSRange(plain.startIndex..<plain.endIndex, in: plain)
        )
        for match in matches.reversed() {
            guard let url = match.url,
                  let stringRange = Range(match.range, in: plain),
                  let range = Range(stringRange, in: attributed) else { continue }
            let alreadyStyled = attributed[range].runs.contains { run in
                run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
            }
            guard !alreadyStyled else { continue }
            attributed[range].link = url
        }
    }
}
