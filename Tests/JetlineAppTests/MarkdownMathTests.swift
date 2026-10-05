#if os(macOS)
import XCTest
@testable import JetlineApp

final class MarkdownMathTests: XCTestCase {
    private func spans(_ source: String) -> [MarkdownMath.Span] {
        MarkdownMath.extract(source)?.spans ?? []
    }

    func testDollarSpans() {
        let result = MarkdownMath.extract("area is $\\pi r^2$ here")
        XCTAssertEqual(result?.0, "area is \(MarkdownMath.placeholder(0)) here")
        XCTAssertEqual(result?.1, [MarkdownMath.Span(tex: "\\pi r^2", display: false)])
    }

    func testCurrencyStaysProse() {
        XCTAssertNil(MarkdownMath.extract("costs $5 and $10"))
        XCTAssertNil(MarkdownMath.extract("from $5-$10 a month"))
        XCTAssertNil(MarkdownMath.extract("just $ signs $ around"))
    }

    func testEscapedDollarIsLeftToMarkdown() {
        XCTAssertNil(MarkdownMath.extract("\\$x\\$"))
    }

    func testCodeSpansAreSkipped() {
        XCTAssertNil(MarkdownMath.extract("run `echo $HOME$` now"))
        XCTAssertEqual(spans("`$a$` and $b$"), [MarkdownMath.Span(tex: "b", display: false)])
    }

    func testOtherDelimiters() {
        XCTAssertEqual(spans("inline \\(x+1\\) and \\[y\\] and $$z$$"), [
            MarkdownMath.Span(tex: "x+1", display: false),
            MarkdownMath.Span(tex: "y", display: true),
            MarkdownMath.Span(tex: "z", display: true),
        ])
    }

    func testDisplayMathBlocks() {
        XCTAssertEqual(MarkdownParser.parse("$$\n\\frac{a}{b}\n$$"), [.math("\\frac{a}{b}")])
        XCTAssertEqual(MarkdownParser.parse("$$ e^{i\\pi} + 1 = 0 $$"), [.math("e^{i\\pi} + 1 = 0")])
        XCTAssertEqual(MarkdownParser.parse("text\n\\[\nx\n\\]\nafter"), [.paragraph("text"), .math("x"), .paragraph("after")])
    }

    func testUnclosedDisplayMathIsAParagraph() {
        XCTAssertEqual(MarkdownParser.parse("$$\nx + y"), [.paragraph("$$\nx + y")])
    }

    func testInlineDisplayMathStaysInItsParagraph() {
        XCTAssertEqual(MarkdownParser.parse("$$a$$ and more"), [.paragraph("$$a$$ and more")])
    }

    func testFenceClosedness() {
        XCTAssertEqual(MarkdownParser.parse("```mermaid\ngraph TD\n```"), [.code(language: "mermaid", text: "graph TD", closed: true)])
        XCTAssertEqual(MarkdownParser.parse("```mermaid\ngraph TD"), [.code(language: "mermaid", text: "graph TD", closed: false)])
    }

    func testFenceLanguages() {
        XCTAssertEqual(SyntaxLanguage.forFence("swift")?.name, "Swift")
        XCTAssertEqual(SyntaxLanguage.forFence("TypeScript")?.name, SyntaxLanguage.javascript.name)
        XCTAssertEqual(SyntaxLanguage.forFence("bash")?.name, SyntaxLanguage.shell.name)
        XCTAssertNil(SyntaxLanguage.forFence("text"))
    }
}
#endif
