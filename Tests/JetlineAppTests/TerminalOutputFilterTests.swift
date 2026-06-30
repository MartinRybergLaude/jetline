import Foundation
import XCTest
@testable import JetlineApp

final class TerminalOutputFilterTests: XCTestCase {
    func testDropsStandaloneOscTitleUpdates() {
        XCTAssertTrue(TerminalOutputFilter.shouldDropStandaloneTitleUpdate(data("\u{1B}]0;busy\u{07}")))
        XCTAssertTrue(TerminalOutputFilter.shouldDropStandaloneTitleUpdate(data("\u{1B}]2;busy\u{1B}\\")))
    }

    func testStripsOscTitlePrefixFromMixedChunk() {
        let input = data("\u{1B}]0;busy\u{07}\u{1B}[?2026hhello")
        XCTAssertEqual(
            TerminalOutputFilter.removingTitleUpdates(input),
            data("\u{1B}[?2026hhello")
        )
    }

    func testStripsOscTitleUpdateInMiddleOfChunk() {
        let input = data("before\u{1B}]2;busy\u{1B}\\after")
        XCTAssertEqual(
            TerminalOutputFilter.removingTitleUpdates(input),
            data("beforeafter")
        )
    }

    func testStripsMultipleOscTitleUpdates() {
        let input = data("\u{1B}]0;one\u{07}hello\u{1B}]2;two\u{1B}\\")
        XCTAssertEqual(TerminalOutputFilter.removingTitleUpdates(input), data("hello"))
    }

    func testDoesNotDropNonTitleOutput() {
        XCTAssertFalse(TerminalOutputFilter.shouldDropStandaloneTitleUpdate(data("\u{1B}[?2026hhello")))
        XCTAssertFalse(TerminalOutputFilter.shouldDropStandaloneTitleUpdate(data("hello\u{1B}]0;busy\u{07}")))
        XCTAssertFalse(TerminalOutputFilter.shouldDropStandaloneTitleUpdate(data("\u{1B}]1;icon\u{07}")))
    }

    func testLeavesUnterminatedOscTitleUpdateAlone() {
        let input = data("hello\u{1B}]0;busy")
        XCTAssertEqual(TerminalOutputFilter.removingTitleUpdates(input), input)
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
