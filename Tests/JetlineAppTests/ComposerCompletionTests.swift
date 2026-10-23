#if os(macOS)
import XCTest
@testable import JetlineApp

final class ComposerCompletionTests: XCTestCase {
    func testSlashCompletesWhereverAWordStarts() {
        let start = ComposerCompletion.detect(in: "/rev", caret: 4)
        XCTAssertEqual(start?.kind, .command)
        XCTAssertEqual(start?.query, "rev")

        let text = "please run /simp"
        let middle = ComposerCompletion.detect(in: text, caret: (text as NSString).length)
        XCTAssertEqual(middle?.kind, .command)
        XCTAssertEqual(middle?.query, "simp")
        XCTAssertEqual(middle?.range, NSRange(location: 11, length: 5))

        let afterNewline = ComposerCompletion.detect(in: "hi\n/", caret: 4)
        XCTAssertEqual(afterNewline?.kind, .command)
        XCTAssertEqual(afterNewline?.query, "")
    }

    func testPluginPrefixIsDroppedFromDescriptions() {
        let plugin = AgentSlashCommand(name: "mattpocock-skills:grill-me", description: "(mattpocock-skills) A relentless interview")
        XCTAssertEqual(ChatComposer.description(of: plugin), "A relentless interview")
        let plain = AgentSlashCommand(name: "review", description: "(user) Review the diff")
        XCTAssertEqual(ChatComposer.description(of: plain), "(user) Review the diff")
        XCTAssertNil(ChatComposer.description(of: AgentSlashCommand(name: "x:y", description: "(x) ")))
    }

    func testSlashInsideAWordDoesNotComplete() {
        XCTAssertNil(ComposerCompletion.detect(in: "see src/main", caret: 12))
    }
}
#endif
