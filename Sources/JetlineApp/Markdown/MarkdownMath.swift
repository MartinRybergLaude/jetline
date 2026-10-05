#if os(macOS)
import Foundation

/// Inline TeX in a paragraph's source: `$…$`, `\(…\)`, and `$$…$$` or
/// `\[…\]` mid-line.
///
/// `$` doubles as a currency sign, so it follows Pandoc's rules: the opening
/// `$` has a non-space after it, the closing one a non-space before it and
/// no digit after it. "$5 and $10" stays prose. Code spans and `\$` are
/// left alone.
enum MarkdownMath {
    struct Span: Equatable {
        var tex: String
        /// `$$…$$` / `\[…\]`: set in display style.
        var display: Bool
    }

    /// Stand-in for span `n` in the rewritten source: private-use
    /// characters that no markdown syntax touches, so they come out of
    /// inline parsing intact.
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"

    /// `source` with each span replaced by `open` + index + `close`, and the
    /// spans. Returns nil when there is no math, which is nearly always.
    static func extract(_ source: String) -> (source: String, spans: [Span])? {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\[") else { return nil }
        let chars = Array(source)
        var out = ""
        var spans: [Span] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                // A code span: copy it through to its matching run.
                let run = runLength(chars, i, "`")
                if let end = findRun(chars, from: i + run, "`", length: run) {
                    out += String(chars[i..<end + run])
                    i = end + run
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
                continue
            }
            if i + 1 < chars.count, let (open, close, display) = delimited.first(where: { $0.open == (c, chars[i + 1]) }) {
                if let end = find(chars, from: i + 2, close) {
                    let tex = String(chars[i + 2..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tex.isEmpty {
                        out += placeholder(spans.count)
                        spans.append(Span(tex: tex, display: display))
                        i = end + 2
                        continue
                    }
                }
                out.append(open.0)
                out.append(open.1)
                i += 2
                continue
            }
            if c == "\\", i + 1 < chars.count {
                // Any other escape, `\$` included, is markdown's business.
                out.append(c)
                out.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$", let end = closingDollar(chars, from: i + 1) {
                out += placeholder(spans.count)
                spans.append(Span(tex: String(chars[i + 1..<end]), display: false))
                i = end + 1
                continue
            }
            out.append(c)
            i += 1
        }
        return spans.isEmpty ? nil : (out, spans)
    }

    /// Two-character delimiters around a span.
    private static let delimited: [(open: (Character, Character), close: (Character, Character), display: Bool)] = [
        (("$", "$"), ("$", "$"), true),
        (("\\", "("), ("\\", ")"), false),
        (("\\", "["), ("\\", "]"), true),
    ]

    static func placeholder(_ index: Int) -> String {
        "\(open)\(index)\(close)"
    }

    /// The closing `$` of an inline span whose content starts at `start`.
    private static func closingDollar(_ chars: [Character], from start: Int) -> Int? {
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != "$" else { return nil }
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "$" {
                let before = chars[i - 1]
                let after: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if before.isWhitespace || after?.isNumber == true { return nil }
                return i
            }
            i += 1
        }
        return nil
    }

    private static func runLength(_ chars: [Character], _ start: Int, _ c: Character) -> Int {
        var i = start
        while i < chars.count, chars[i] == c { i += 1 }
        return i - start
    }

    private static func findRun(_ chars: [Character], from start: Int, _ c: Character, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == c {
                let run = runLength(chars, i, c)
                if run == length { return i }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Index of the first `token` at or after `start`.
    private static func find(_ chars: [Character], from start: Int, _ token: (Character, Character)) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == token.0, chars[i + 1] == token.1 { return i }
            i += 1
        }
        return nil
    }
}
#endif
