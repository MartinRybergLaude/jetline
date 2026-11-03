import XCTest
@testable import JetlineApp

final class AgentItemAppendTests: XCTestCase {
    private let delta = String(repeating: "x", count: 1024)
    private let deltas = 16 * 1024

    /// A build log streams in thousands of deltas. Appending while the
    /// item's content still held the text copied all of it each time:
    /// 16 MB of output was some 128 GB of copying.
    func testStreamedCommandOutputGrowsInPlace() {
        var item = AgentItem(id: "c", turnId: "t", status: .inProgress, content: .command(.init(command: "make")))
        let started = ContinuousClock.now
        for _ in 0..<deltas { item.append(delta, kind: .commandOutput) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        guard case .command(let command) = item.content else { return XCTFail("content changed kind") }
        XCTAssertEqual(command.output.utf8.count, deltas * delta.utf8.count)
    }

    func testEveryStreamLandsInItsField() {
        func appended(_ content: AgentItem.Content, _ kind: AgentStreamKind) -> AgentItem.Content {
            var item = AgentItem(id: "i", turnId: nil, status: .inProgress, content: content)
            item.append("b", kind: kind)
            item.append("c", kind: kind)
            return item.content
        }
        XCTAssertEqual(appended(.assistantMessage(text: "a"), .assistantText), .assistantMessage(text: "abc"))
        XCTAssertEqual(appended(.reasoning(text: "a"), .reasoningText), .reasoning(text: "abc"))
        XCTAssertEqual(appended(.plan(text: "a"), .planText), .plan(text: "abc"))
        XCTAssertEqual(appended(.command(.init(command: "ls", output: "a")), .commandOutput), .command(.init(command: "ls", output: "abc")))
        XCTAssertEqual(appended(.tool(.init(name: "t")), .toolOutput), .tool(.init(name: "t", output: "bc")))
        // A stream for another field leaves the item alone.
        XCTAssertEqual(appended(.reasoning(text: "a"), .assistantText), .reasoning(text: "a"))
    }
}
