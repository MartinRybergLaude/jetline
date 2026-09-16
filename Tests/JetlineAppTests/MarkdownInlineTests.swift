import XCTest
@testable import JetlineApp

final class MarkdownInlineTests: XCTestCase {
    private func plain(_ source: String) -> String {
        String(MarkdownInline.parse(source).characters)
    }

    func testEmphasisMarkersAreConsumed() {
        XCTAssertEqual(plain("**bold** and *italic*"), "bold and italic")
    }

    func testCodeSpanIsMarked() {
        let attributed = MarkdownInline.parse("call `foo()` now")
        let codeRuns = attributed.runs.filter {
            $0.inlinePresentationIntent?.contains(.code) == true
        }
        XCTAssertEqual(codeRuns.count, 1)
        XCTAssertEqual(String(attributed[codeRuns[0].range].characters), "foo()")
    }

    func testKnownHTMLTagsAreStripped() {
        XCTAssertEqual(plain("a <sub>small</sub> b"), "a small b")
        XCTAssertEqual(plain("<img src=\"x.png\" alt=\"a > b\">tail"), "tail")
    }

    func testBreakTagBecomesANewline() {
        XCTAssertEqual(plain("one<br>two"), "one\ntwo")
    }

    /// The whole reason the tag allowlist exists: a generic parameter looks
    /// exactly like a tag to a naive stripper.
    func testGenericParametersSurvive() {
        XCTAssertEqual(plain("returns Array<Int> always"), "returns Array<Int> always")
    }

    func testTagsInsideCodeSpansSurvive() {
        let attributed = MarkdownInline.parse("use `<br>` there")
        XCTAssertEqual(String(attributed.characters), "use <br> there")
    }

    /// Entity decoding is Foundation's job — these pin the behavior we rely
    /// on, including that a doubly-escaped entity stays literal.
    func testEntitiesAreDecodedOnce() {
        XCTAssertEqual(plain("a &amp; b"), "a & b")
        XCTAssertEqual(plain("&amp;lt;"), "&lt;")
        XCTAssertEqual(plain("&#39;quoted&#39;"), "'quoted'")
        XCTAssertEqual(plain("&#x2713; done"), "✓ done")
    }

    func testUnknownEntityIsLeftAlone() {
        XCTAssertEqual(plain("AT&T; fine"), "AT&T; fine")
    }

    func testBareURLIsAutolinked() {
        let attributed = MarkdownInline.parse("see https://example.com/x for more")
        let links = attributed.runs.compactMap(\.link)
        XCTAssertEqual(links.map(\.absoluteString), ["https://example.com/x"])
    }

    func testMarkdownLinkKeepsItsLabel() {
        let attributed = MarkdownInline.parse("[label](https://example.com)")
        XCTAssertEqual(String(attributed.characters), "label")
        XCTAssertEqual(attributed.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
    }

    /// A URL sitting inside a code span is sample text, not a destination.
    func testURLInsideCodeSpanIsNotLinked() {
        let attributed = MarkdownInline.parse("`https://example.com`")
        XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil })
    }
}
