import XCTest
@testable import JetlineApp

final class MarkdownParserTests: XCTestCase {
    func testParagraphsSplitOnBlankLines() {
        let blocks = MarkdownParser.parse("first line\nstill first\n\nsecond")
        XCTAssertEqual(blocks, [.paragraph("first line\nstill first"), .paragraph("second")])
    }

    func testATXHeadings() {
        let blocks = MarkdownParser.parse("# Title\n\n### Deep ###\n\n#NotAHeading")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "Title"),
            .heading(level: 3, text: "Deep"),
            .paragraph("#NotAHeading")
        ])
    }

    func testSetextHeadingsBeatThematicBreaks() {
        let blocks = MarkdownParser.parse("Title\n---\n\nbody")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "Title"), .paragraph("body")])
    }

    func testStandaloneDashesAreAThematicBreak() {
        XCTAssertEqual(MarkdownParser.parse("---"), [.rule])
        XCTAssertEqual(MarkdownParser.parse("a\n\n---\n\nb"), [
            .paragraph("a"), .rule, .paragraph("b")
        ])
    }

    func testFencedCodeKeepsItsContentVerbatim() {
        let source = """
        ```swift
        # not a heading
        - not a list
        ```
        """
        XCTAssertEqual(
            MarkdownParser.parse(source),
            [.code(language: "swift", text: "# not a heading\n- not a list")]
        )
    }

    func testTildeFenceAndMissingCloser() {
        let blocks = MarkdownParser.parse("~~~\nplain\n")
        XCTAssertEqual(blocks, [.code(language: nil, text: "plain")])
    }

    /// The fence's own indentation is stripped so a code block nested in a
    /// list item doesn't render with four dead columns.
    func testIndentedFenceIsDedented() {
        let source = "    ```\n    let x = 1\n    ```"
        XCTAssertEqual(MarkdownParser.parse(source), [.code(language: nil, text: "let x = 1")])
    }

    func testInlineCodeSpanIsNotAFence() {
        XCTAssertEqual(MarkdownParser.parse("```code```"), [.paragraph("```code```")])
    }

    func testUnorderedListWithWrappedContinuation() {
        let source = """
        - first item
          wrapped
        - second
        """
        guard case let .list(list)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a list")
        }
        XCTAssertFalse(list.ordered)
        XCTAssertEqual(list.items.count, 2)
        XCTAssertEqual(list.items[0].blocks, [.paragraph("first item\nwrapped")])
        XCTAssertEqual(list.items[1].blocks, [.paragraph("second")])
    }

    func testOrderedListKeepsItsStartingNumber() {
        guard case let .list(list)? = MarkdownParser.parse("3. three\n4. four").first else {
            return XCTFail("expected a list")
        }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.start, 3)
        XCTAssertEqual(list.items.count, 2)
    }

    func testNestedListBecomesAChildBlock() {
        let source = """
        - outer
          - inner a
          - inner b
        """
        guard case let .list(list)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items[0].blocks.count, 2)
        guard case let .list(inner) = list.items[0].blocks[1] else {
            return XCTFail("expected a nested list")
        }
        XCTAssertEqual(inner.items.count, 2)
    }

    func testTaskItems() {
        guard case let .list(list)? = MarkdownParser.parse("- [x] done\n- [ ] todo\n- plain").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(list.items.map(\.checked), [true, false, nil])
        XCTAssertEqual(list.items[0].blocks, [.paragraph("done")])
    }

    func testHyphenatedWordIsNotAList() {
        XCTAssertEqual(MarkdownParser.parse("-notalist"), [.paragraph("-notalist")])
    }

    func testBlockQuoteParsesItsContents() {
        let blocks = MarkdownParser.parse("> quoted **text**\n> more")
        XCTAssertEqual(blocks, [.quote([.paragraph("quoted **text**\nmore")])])
    }

    func testTableWithAlignments() {
        let source = """
        | File | Description | Count |
        | ---- | :---------: | ----: |
        | a.swift | does a | 1 |
        | b.swift | does b | 2 |
        """
        guard case let .table(table)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.header, ["File", "Description", "Count"])
        XCTAssertEqual(table.alignments, [.leading, .center, .trailing])
        XCTAssertEqual(table.rows, [["a.swift", "does a", "1"], ["b.swift", "does b", "2"]])
    }

    func testRaggedTableRowsArePaddedToTheHeaderWidth() {
        let source = "| a | b |\n| - | - |\n| only |"
        guard case let .table(table)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.rows, [["only", ""]])
    }

    func testEscapedPipeStaysInsideItsCell() {
        let source = "| a | b |\n| - | - |\n| x \\| y | z |"
        guard case let .table(table)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(table.rows, [["x | y", "z"]])
    }

    func testProseWithPipesIsNotATable() {
        let blocks = MarkdownParser.parse("use a | b here\nand more text")
        XCTAssertEqual(blocks, [.paragraph("use a | b here\nand more text")])
    }

    func testDetailsBecomesADisclosure() {
        let source = """
        <details>
        <summary>Show a summary per file</summary>

        | File | Description |
        | ---- | ----------- |
        | a.swift | does a |

        </details>
        """
        guard case let .details(summary, blocks)? = MarkdownParser.parse(source).first else {
            return XCTFail("expected a disclosure")
        }
        XCTAssertEqual(summary, "Show a summary per file")
        XCTAssertEqual(blocks.count, 1)
        guard case .table = blocks[0] else { return XCTFail("expected the table inside") }
    }

    func testDetailsWithoutSummaryFallsBackToALabel() {
        guard case let .details(summary, blocks)? = MarkdownParser.parse("<details>\nbody\n</details>").first else {
            return XCTFail("expected a disclosure")
        }
        XCTAssertEqual(summary, "Details")
        XCTAssertEqual(blocks, [.paragraph("body")])
    }

    /// Bot reviews nest a `<details>` per file inside an outer one; a naive
    /// scan would stop at the first `</details>` and spill the rest.
    func testNestedDetailsClosesAtTheMatchingTag() {
        let source = """
        <details>
        <summary>outer</summary>
        <details>
        <summary>inner</summary>
        deep
        </details>
        </details>

        after
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 2)
        guard case let .details(summary, inner) = blocks[0] else {
            return XCTFail("expected a disclosure")
        }
        XCTAssertEqual(summary, "outer")
        guard case let .details(innerSummary, _)? = inner.first else {
            return XCTFail("expected a nested disclosure")
        }
        XCTAssertEqual(innerSummary, "inner")
        XCTAssertEqual(blocks[1], .paragraph("after"))
    }

    func testCRLFAndTabsAreNormalized() {
        let blocks = MarkdownParser.parse("- a\r\n\t- b\r\n")
        guard case let .list(list)? = blocks.first else { return XCTFail("expected a list") }
        XCTAssertEqual(list.items.count, 1)
        XCTAssertEqual(list.items[0].blocks.count, 2)
    }

    func testEmptySourceProducesNoBlocks() {
        XCTAssertEqual(MarkdownParser.parse(""), [])
        XCTAssertEqual(MarkdownParser.parse("\n\n   \n"), [])
    }
}
