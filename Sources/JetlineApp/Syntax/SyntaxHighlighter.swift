import AppKit

enum SyntaxTokenKind: Equatable, Sendable {
    case keyword, string, comment, number, type, attribute, variable
}

/// A run of one line's text, colored as `kind` (plain when nil).
struct SyntaxSegment: Equatable, Sendable {
    var text: String
    var kind: SyntaxTokenKind?
}

/// Line-at-a-time lexer. Whatever is still open at the end of a line — a
/// block comment, a multi-line string — is carried in `State` to the next
/// line, so callers tokenize a file's lines in order.
struct SyntaxHighlighter: Sendable {
    let language: SyntaxLanguage

    enum State: Equatable, Sendable {
        case normal
        case blockComment
        /// Inside a multi-line string closed by the associated delimiter.
        case string(close: String)
    }

    func tokenize(_ line: String, state: inout State) -> [SyntaxSegment] {
        var lexer = Lexer(chars: Array(line), language: language)
        lexer.run(state: &state)
        return lexer.segments
    }

    private struct Lexer {
        let chars: [Character]
        let language: SyntaxLanguage
        var segments: [SyntaxSegment] = []
        private var plain = ""

        init(chars: [Character], language: SyntaxLanguage) {
            self.chars = chars
            self.language = language
        }

        mutating func run(state: inout State) {
            var i = 0
            switch state {
            case .normal:
                break
            case .blockComment:
                guard let close = language.blockComment?.close,
                      let end = find(close, from: 0) else {
                    emit(0, chars.count, .comment); return
                }
                emit(0, end, .comment)
                i = end
                state = .normal
            case .string(let close):
                guard let end = findStringEnd(close, from: 0) else {
                    emit(0, chars.count, .string); return
                }
                emit(0, end, .string)
                i = end
                state = .normal
            }

            let multiline = language.multilineStrings.sorted { $0.count > $1.count }
            while i < chars.count {
                let c = chars[i]

                if language.lineComments.contains(where: { matches($0, at: i) }) {
                    emit(i, chars.count, .comment); break
                }
                if let block = language.blockComment, matches(block.open, at: i) {
                    if let end = find(block.close, from: i + block.open.count) {
                        emit(i, end, .comment); i = end; continue
                    }
                    emit(i, chars.count, .comment)
                    state = .blockComment
                    break
                }
                if let delim = multiline.first(where: { matches($0, at: i) }) {
                    if let end = findStringEnd(delim, from: i + delim.count) {
                        emit(i, end, .string); i = end; continue
                    }
                    emit(i, chars.count, .string)
                    state = .string(close: delim)
                    break
                }
                if language.stringDelimiters.contains(c) {
                    let end = findStringEnd(String(c), from: i + 1) ?? chars.count
                    emit(i, end, .string); i = end; continue
                }
                if c.isNumber, i == 0 || !Self.isIdent(chars[i - 1]) {
                    let end = numberEnd(from: i)
                    emit(i, end, .number); i = end; continue
                }
                if language.atAttributes, c == "@", i + 1 < chars.count, Self.isIdentStart(chars[i + 1]) {
                    let end = identEnd(from: i + 1)
                    emit(i, end, .attribute); i = end; continue
                }
                if language.hashDirectives, c == "#", i + 1 < chars.count,
                   Self.isIdentStart(chars[i + 1]) {
                    let end = identEnd(from: i + 1)
                    emit(i, end, .attribute); i = end; continue
                }
                if language.dollarVariables, c == "$", i + 1 < chars.count {
                    let next = chars[i + 1]
                    if next == "{", let close = find("}", from: i + 2) {
                        emit(i, close, .variable); i = close; continue
                    }
                    if Self.isIdentStart(next) || next.isNumber {
                        let end = identEnd(from: i + 1)
                        emit(i, end, .variable); i = end; continue
                    }
                }
                if Self.isIdentStart(c) {
                    let end = identEnd(from: i)
                    emit(i, end, classify(String(chars[i..<end])))
                    i = end; continue
                }
                plain.append(c)
                i += 1
            }
            flushPlain()
        }

        private func classify(_ word: String) -> SyntaxTokenKind? {
            let key = language.caseInsensitiveKeywords ? word.lowercased() : word
            if language.keywords.contains(key) || language.literals.contains(key) { return .keyword }
            if language.capitalizedAreTypes, word.first?.isUppercase == true,
               word.contains(where: \.isLowercase) {
                return .type
            }
            return nil
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind?) {
            guard start < end else { return }
            let text = String(chars[start..<end])
            guard let kind else { plain += text; return }
            flushPlain()
            segments.append(SyntaxSegment(text: text, kind: kind))
        }

        private mutating func flushPlain() {
            guard !plain.isEmpty else { return }
            segments.append(SyntaxSegment(text: plain, kind: nil))
            plain = ""
        }

        private func matches(_ token: String, at i: Int) -> Bool {
            var j = i
            for t in token {
                guard j < chars.count, chars[j] == t else { return false }
                j += 1
            }
            return true
        }

        /// Index just past the first `token` at or after `from`.
        private func find(_ token: String, from: Int) -> Int? {
            var i = from
            while i < chars.count {
                if matches(token, at: i) { return i + token.count }
                i += 1
            }
            return nil
        }

        /// Like `find`, but skips backslash-escaped characters.
        private func findStringEnd(_ close: String, from: Int) -> Int? {
            var i = from
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if matches(close, at: i) { return i + close.count }
                i += 1
            }
            return nil
        }

        private func numberEnd(from start: Int) -> Int {
            var i = start + 1
            while i < chars.count {
                let c = chars[i]
                if c.isHexDigit || c == "_" || c == "x" || c == "X" || c == "o" || c == "b" {
                    i += 1
                } else if c == ".", i + 1 < chars.count, chars[i + 1].isNumber {
                    i += 1
                } else {
                    break
                }
            }
            return i
        }

        private func identEnd(from start: Int) -> Int {
            var i = start
            while i < chars.count, Self.isIdent(chars[i]) { i += 1 }
            return i
        }

        static func isIdentStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
        static func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
    }
}

/// Token colors, after Xcode's default light and dark themes. Dynamic
/// `NSColor`s, so text already on screen follows an appearance flip.
enum SyntaxTheme {
    static func color(_ kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword:   return keyword
        case .string:    return string
        case .comment:   return comment
        case .number:    return number
        case .type:      return type
        case .attribute: return attribute
        case .variable:  return variable
        }
    }

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
        return NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static let keyword   = dynamic("syntaxKeyword",   light: 0x9B2393, dark: 0xFC5FA3)
    private static let string    = dynamic("syntaxString",    light: 0xC41A16, dark: 0xFC6A5D)
    private static let comment   = dynamic("syntaxComment",   light: 0x5D6C79, dark: 0x7F8C98)
    private static let number    = dynamic("syntaxNumber",    light: 0x1C00CF, dark: 0xD0BF69)
    private static let type      = dynamic("syntaxType",      light: 0x0B4F79, dark: 0x5DD8FF)
    private static let attribute = dynamic("syntaxAttribute", light: 0x815F03, dark: 0xFD8F3F)
    private static let variable  = dynamic("syntaxVariable",  light: 0x326D74, dark: 0x67B7A4)
}
