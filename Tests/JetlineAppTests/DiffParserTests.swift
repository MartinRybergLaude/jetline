import XCTest
@testable import JetlineApp

final class DiffParserTests: XCTestCase {
    func testParsesSingleFilePatch() {
        let patch = """
        diff --git a/foo.txt b/foo.txt
        index 0000000..1111111 100644
        --- a/foo.txt
        +++ b/foo.txt
        @@ -1,3 +1,3 @@
         line1
        -old
        +new
         line3
        """

        let files = PatchParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].path, "foo.txt")
        XCTAssertEqual(files[0].hunks.count, 1)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.filter { $0.kind == .addition }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .deletion }.count, 1)
    }

    func testWorktreeSlug() {
        XCTAssertEqual(WorktreeOps.slug("Fix the API!! v2"), "fix-the-api-v2")
        XCTAssertEqual(WorktreeOps.slug(""), "workspace")
        XCTAssertEqual(WorktreeOps.slug("////"), "workspace")
    }
}
