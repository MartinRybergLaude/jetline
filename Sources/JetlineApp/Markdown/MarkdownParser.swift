import Foundation

/// Line-oriented GitHub-flavored markdown block parser.
///
/// Scope is deliberately "what shows up in PR comments": fenced code,
/// headings, lists (nested, task items), block quotes, GFM pipe tables,
/// thematic breaks, and `<details>` disclosures. Everything else degrades
/// to a paragraph rather than being dropped.
///
/// Recursion works by slicing the relevant lines out and re-entering
/// `parseBlocks` on them, so nothing has to thread an indentation context
/// through every helper.
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        parseBlocks(normalize(source).components(separatedBy: "\n"))
    }

    /// Tabs are expanded up front so every indentation comparison in the
    /// parser can count plain spaces. Inside code blocks this is a cosmetic
    /// change, and 4-wide reads better than a terminal's 8 in a narrow panel.
    ///
    /// Each rewrite is guarded: GitHub bodies are almost always already
    /// LF-only and tab-free, and an unguarded `replacingOccurrences` copies
    /// the whole body to change nothing.
    private static func normalize(_ source: String) -> String {
        var out = source
        if out.contains("\r") {
            out = out.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
        }
        if out.contains("\t") {
            out = out.replacingOccurrences(of: "\t", with: "    ")
        }
        return out
    }

    // MARK: - Block loop

    private static func parseBlocks(_ lines: [String]) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            if isBlank(lines[i]) { i += 1; continue }

            // Trimmed once here and threaded through: every `take*` below
            // needs it, and re-trimming in each one allocated half a dozen
            // throwaway strings per line before any block was recognised.
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

            // Fences come first: a ``` block can contain anything, including
            // text that would otherwise read as a heading or a list.
            if let block = takeFence(lines, &i) { out.append(block); continue }
            if let block = takeDetails(lines, &i, trimmed: trimmed) { out.append(block); continue }
            if let block = takeHeading(&i, trimmed: trimmed) { out.append(block); continue }
            if let block = takeRule(&i, trimmed: trimmed) { out.append(block); continue }
            if let block = takeQuote(lines, &i, trimmed: trimmed) { out.append(block); continue }
            if let block = takeList(lines, &i) { out.append(block); continue }
            if let block = takeTable(lines, &i) { out.append(block); continue }
            out.append(contentsOf: takeParagraph(lines, &i))
        }
        return out
    }

    /// Block starters that terminate a paragraph's lazy continuation. Lists
    /// and tables are handled by their own callers because they need more
    /// context (a table needs its delimiter row) or are allowed to interrupt.
    private static func startsNewBlock(_ line: String) -> Bool {
        startsNewBlock(line, trimmed: line.trimmingCharacters(in: .whitespaces))
    }

    private static func startsNewBlock(_ line: String, trimmed: String) -> Bool {
        if fenceInfo(line) != nil { return true }
        if trimmed.hasPrefix(">") { return true }
        if trimmed.lowercased().hasPrefix("<details") { return true }
        if headingLevel(trimmed) != nil { return true }
        if isRule(trimmed) { return true }
        return false
    }

    // MARK: - Fenced code

    /// Returns `(fenceCharacter, runLength, infoString)` when `line` opens or
    /// closes a fence.
    private static func fenceInfo(_ line: String) -> (Character, Int, String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        let info = trimmed.dropFirst(run).trimmingCharacters(in: .whitespaces)
        // An opening backtick fence's info string may not contain a backtick
        // — that rules out inline code spans like ```a``` on their own line.
        if first == "`" && info.contains("`") { return nil }
        return (first, run, info)
    }

    private static func takeFence(_ lines: [String], _ i: inout Int) -> MarkdownBlock? {
        guard let (char, run, info) = fenceInfo(lines[i]) else { return nil }
        let indent = indentWidth(lines[i])
        var body: [String] = []
        i += 1
        while i < lines.count {
            if let (closeChar, closeRun, closeInfo) = fenceInfo(lines[i]),
               closeChar == char, closeRun >= run, closeInfo.isEmpty {
                i += 1
                break
            }
            body.append(dedent(lines[i], by: indent))
            i += 1
        }
        // Trailing blank lines inside a fence are almost always accidental
        // and cost real vertical space in a narrow inspector.
        while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            body.removeLast()
        }
        let language = info.split(separator: " ").first.map { $0.lowercased() }
        return .code(language: language, text: body.joined(separator: "\n"))
    }

    // MARK: - Headings

    private static func headingLevel(_ trimmed: String) -> Int? {
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return hashes
    }

    private static func takeHeading(_ i: inout Int, trimmed: String) -> MarkdownBlock? {
        guard let level = headingLevel(trimmed) else { return nil }
        var text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
        // Closing sequence: `## Title ##`.
        while text.hasSuffix("#") { text.removeLast() }
        i += 1
        return .heading(level: level, text: text.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - Thematic break

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
        var count = 0
        for ch in trimmed {
            if ch == first { count += 1 } else if ch != " " { return false }
        }
        return count >= 3
    }

    private static func takeRule(_ i: inout Int, trimmed: String) -> MarkdownBlock? {
        guard isRule(trimmed) else { return nil }
        i += 1
        return .rule
    }

    // MARK: - Block quote

    private static func takeQuote(
        _ lines: [String],
        _ i: inout Int,
        trimmed firstTrimmed: String
    ) -> MarkdownBlock? {
        guard firstTrimmed.hasPrefix(">") else { return nil }
        var inner: [String] = []
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = String(trimmed.dropFirst())
            if content.hasPrefix(" ") { content.removeFirst() }
            inner.append(content)
            i += 1
        }
        return .quote(parseBlocks(inner))
    }

    // MARK: - Lists

    private struct ListMarker {
        var indent: Int
        var ordered: Bool
        var number: Int
        /// Column the item's body starts at — continuation lines indented at
        /// least this far belong to the item.
        var contentIndent: Int
        var rest: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentWidth(line)
        var idx = line.index(line.startIndex, offsetBy: min(indent, line.count))
        guard idx < line.endIndex else { return nil }

        var ordered = false
        var number = 1
        var markerWidth = 0

        let first = line[idx]
        if first == "-" || first == "*" || first == "+" {
            markerWidth = 1
            idx = line.index(after: idx)
        } else if first.isNumber {
            var digits = ""
            var scan = idx
            while scan < line.endIndex, line[scan].isNumber, digits.count < 9 {
                digits.append(line[scan])
                scan = line.index(after: scan)
            }
            guard scan < line.endIndex, line[scan] == "." || line[scan] == ")" else { return nil }
            number = Int(digits) ?? 1
            ordered = true
            markerWidth = digits.count + 1
            idx = line.index(after: scan)
        } else {
            return nil
        }

        var spaces = 0
        while idx < line.endIndex, line[idx] == " " {
            spaces += 1
            idx = line.index(after: idx)
        }
        // `-foo` is a word, not a bullet. An empty item (marker then EOL) is.
        guard spaces > 0 || idx == line.endIndex else { return nil }

        return ListMarker(
            indent: indent,
            ordered: ordered,
            number: number,
            contentIndent: indent + markerWidth + max(spaces, 1),
            rest: String(line[idx...])
        )
    }

    private static func takeList(_ lines: [String], _ i: inout Int) -> MarkdownBlock? {
        guard let first = listMarker(lines[i]) else { return nil }
        let baseIndent = first.indent
        let ordered = first.ordered
        var items: [MarkdownList.Item] = []

        while i < lines.count {
            // A marker indented past the previous item's content column was
            // already swallowed as nested content below, so anything we see
            // here at a deeper indent starts a different list.
            guard let marker = listMarker(lines[i]),
                  marker.indent <= baseIndent,
                  marker.ordered == ordered else { break }

            var content = [marker.rest]
            var pendingBlanks: [String] = []
            i += 1

            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    pendingBlanks.append("")
                    i += 1
                    continue
                }
                if indentWidth(line) >= marker.contentIndent {
                    content.append(contentsOf: pendingBlanks)
                    pendingBlanks.removeAll()
                    content.append(dedent(line, by: marker.contentIndent))
                    i += 1
                    continue
                }
                // Lazy continuation of a wrapped line: only while no blank
                // line has intervened and the line doesn't open a new block.
                if pendingBlanks.isEmpty, listMarker(line) == nil, !startsNewBlock(line) {
                    content.append(line.trimmingCharacters(in: .whitespaces))
                    i += 1
                    continue
                }
                break
            }

            var checked: Bool? = nil
            if let box = taskBox(content.first ?? "") {
                checked = box.checked
                content[0] = box.rest
            }
            items.append(MarkdownList.Item(checked: checked, blocks: parseBlocks(content)))
        }

        guard !items.isEmpty else { return nil }
        return .list(MarkdownList(ordered: ordered, start: first.number, items: items))
    }

    private static func taskBox(_ text: String) -> (checked: Bool, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3, trimmed.hasPrefix("[") else { return nil }
        let marker = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)]
        let closing = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)]
        guard closing == "]", marker == " " || marker == "x" || marker == "X" else { return nil }
        let rest = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        return (marker != " ", rest)
    }

    // MARK: - Tables

    private static func takeTable(_ lines: [String], _ i: inout Int) -> MarkdownBlock? {
        guard lines[i].contains("|"), i + 1 < lines.count else { return nil }
        let header = splitTableRow(lines[i])
        guard let alignments = tableDelimiters(lines[i + 1]),
              alignments.count == header.count,
              header.count > 1 else { return nil }

        i += 2
        var rows: [[String]] = []
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            var cells = splitTableRow(lines[i])
            // Ragged rows are common in hand-written tables; normalize so the
            // grid renderer can assume a rectangle.
            if cells.count < header.count {
                cells.append(contentsOf: Array(repeating: "", count: header.count - cells.count))
            } else if cells.count > header.count {
                cells = Array(cells.prefix(header.count))
            }
            rows.append(cells)
            i += 1
        }
        return .table(MarkdownTable(header: header, alignments: alignments, rows: rows))
    }

    private static func tableDelimiters(_ line: String) -> [MarkdownTable.Align]? {
        let cells = splitTableRow(line)
        guard !cells.isEmpty else { return nil }
        var out: [MarkdownTable.Align] = []
        for cell in cells {
            let text = cell.trimmingCharacters(in: .whitespaces)
            let leading = text.hasPrefix(":")
            let trailing = text.hasSuffix(":")
            let dashes = text.dropFirst(leading ? 1 : 0).dropLast(trailing && text.count > 1 ? 1 : 0)
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leading, trailing) {
            case (true, true):  out.append(.center)
            case (false, true): out.append(.trailing)
            default:            out.append(.leading)
            }
        }
        return out
    }

    /// Splits on unescaped `|`, dropping the optional leading/trailing pipes.
    private static func splitTableRow(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line.trimmingCharacters(in: .whitespaces) {
            if escaped {
                // Keep the pipe, drop the backslash — `\|` means a literal
                // pipe inside a cell.
                if ch != "|" { current.append("\\") }
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Disclosure (`<details>`)

    private static func takeDetails(
        _ lines: [String],
        _ i: inout Int,
        trimmed: String
    ) -> MarkdownBlock? {
        guard trimmed.lowercased().hasPrefix("<details") else { return nil }
        var depth = 0
        var collected: [String] = []
        while i < lines.count {
            let lower = lines[i].lowercased()
            depth += occurrences(of: "<details", in: lower)
            depth -= occurrences(of: "</details>", in: lower)
            collected.append(lines[i])
            i += 1
            if depth <= 0 { break }
        }

        var body = collected.joined(separator: "\n")
        if let openEnd = body.firstIndex(of: ">") {
            body = String(body[body.index(after: openEnd)...])
        }
        if let closeStart = body.range(of: "</details>", options: [.caseInsensitive, .backwards]) {
            body = String(body[..<closeStart.lowerBound])
        }

        var summary = "Details"
        if let open = body.range(of: "<summary", options: .caseInsensitive),
           let openEnd = body[open.upperBound...].firstIndex(of: ">"),
           let close = body.range(of: "</summary>", options: .caseInsensitive) {
            summary = String(body[body.index(after: openEnd)..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            body = String(body[..<open.lowerBound]) + String(body[close.upperBound...])
        }

        return .details(
            summary: summary.nonBlank ?? "Details",
            blocks: parseBlocks(body.components(separatedBy: "\n"))
        )
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }

    // MARK: - Paragraph

    /// Returns one block in the usual case, but a setext underline (`===` /
    /// `---` directly beneath text) turns the accumulated lines into a
    /// heading plus, possibly, a preceding paragraph.
    private static func takeParagraph(_ lines: [String], _ i: inout Int) -> [MarkdownBlock] {
        var buffer: [String] = []
        var out: [MarkdownBlock] = []

        func flush() {
            let text = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(.paragraph(text)) }
            buffer.removeAll()
        }

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; break }

            // Setext underline. Checked before the thematic-break and list
            // interrupts so `Title\n---` stays a heading.
            if !buffer.isEmpty, let level = setextLevel(line) {
                let text = buffer.removeLast().trimmingCharacters(in: .whitespaces)
                flush()
                out.append(.heading(level: level, text: text))
                i += 1
                return out
            }

            if !buffer.isEmpty {
                if startsNewBlock(line) { break }
                if listMarker(line) != nil { break }
                if line.contains("|"), i + 1 < lines.count, tableDelimiters(lines[i + 1]) != nil { break }
            }

            buffer.append(line)
            i += 1
        }

        flush()
        return out
    }

    private static func setextLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    // MARK: - Line helpers

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private static func indentWidth(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func dedent(_ line: String, by amount: Int) -> String {
        String(line.dropFirst(min(amount, indentWidth(line))))
    }
}
