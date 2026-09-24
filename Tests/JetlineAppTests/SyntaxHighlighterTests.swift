import XCTest
@testable import JetlineApp

final class SyntaxHighlighterTests: XCTestCase {
    private func kinds(_ line: String, _ language: SyntaxLanguage,
                       state: inout SyntaxHighlighter.State) -> [String] {
        SyntaxHighlighter(language: language).tokenize(line, state: &state).map {
            "\($0.kind.map { "\($0)" } ?? "plain"):\($0.text)"
        }
    }

    func testSwiftLine() {
        var state = SyntaxHighlighter.State.normal
        XCTAssertEqual(kinds(#"let x: Int = 42 // "hi""#, .swift, state: &state), [
            "keyword:let", "plain: x: ", "type:Int", "plain: = ", "number:42", "plain: ",
            #"comment:// "hi""#,
        ])
        XCTAssertEqual(state, .normal)
    }

    func testStringsHonorEscapes() {
        var state = SyntaxHighlighter.State.normal
        XCTAssertEqual(kinds(#"x = "a\"b" + 1"#, .javascript, state: &state), [
            "plain:x = ", #"string:"a\"b""#, "plain: + ", "number:1",
        ])
    }

    func testBlockCommentCarriesAcrossLines() {
        var state = SyntaxHighlighter.State.normal
        _ = kinds("a /* start", .c, state: &state)
        XCTAssertEqual(state, .blockComment)
        XCTAssertEqual(kinds("end */ int", .c, state: &state), ["comment:end */", "plain: ", "keyword:int"])
        XCTAssertEqual(state, .normal)
    }

    func testMultilineStringCarriesAcrossLines() {
        var state = SyntaxHighlighter.State.normal
        _ = kinds(#"doc = """"#, .python, state: &state)
        XCTAssertEqual(state, .string(close: #"""""#))
        XCTAssertEqual(kinds(#"# not a comment""""#, .python, state: &state), [#"string:# not a comment""""#])
        XCTAssertEqual(state, .normal)
    }

    func testIdentifierDigitsAreNotNumbers() {
        var state = SyntaxHighlighter.State.normal
        XCTAssertEqual(kinds("utf8", .go, state: &state), ["plain:utf8"])
    }

    func testLanguageLookup() {
        XCTAssertEqual(SyntaxLanguage.forPath("apps/web/src/x.svelte.ts")?.name, "JavaScript")
        XCTAssertEqual(SyntaxLanguage.forPath("Makefile")?.name, "Shell")
        XCTAssertNil(SyntaxLanguage.forPath("README.md"))
    }

    func testDiffSidesHighlightIndependently() {
        // A deletion that opens a block comment must not color the added line.
        let file = FileDiff(path: "a.c", status: .modified, additions: 1, deletions: 1, hunks: [
            .init(header: "@@ -1,1 +1,1 @@", lines: [
                .init(kind: .deletion, text: "/* old"),
                .init(kind: .addition, text: "int x;"),
            ])
        ])
        let rows = FileDiffLine.lines(for: file, language: .c)
        let added = rows[1].highlighted!
        XCTAssertEqual(added.runs.first.map { String(added[$0.range].characters) }, "int")
    }
}
