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

    func testUntrackedFileDiffSynthesizesAllAdditionHunk() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "line1\nline2\n".write(
            to: dir.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8
        )

        let file = try XCTUnwrap(
            DiffComputer.untrackedFileDiff(path: "new.txt", worktreePath: dir.path)
        )
        XCTAssertEqual(file.status, .added)
        XCTAssertEqual(file.additions, 2)
        XCTAssertEqual(file.deletions, 0)
        XCTAssertFalse(file.isBinary)
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks[0].header, "@@ -0,0 +1,2 @@")
        XCTAssertEqual(file.hunks[0].lines.map(\.text), ["line1", "line2"])
        XCTAssertTrue(file.hunks[0].lines.allSatisfy { $0.kind == .addition })
    }

    func testUntrackedFileDiffSplitsCRLFLines() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "line1\r\nline2\r\nline3\r\n".write(
            to: dir.appendingPathComponent("crlf.csv"), atomically: true, encoding: .utf8
        )

        let file = try XCTUnwrap(
            DiffComputer.untrackedFileDiff(path: "crlf.csv", worktreePath: dir.path)
        )
        XCTAssertEqual(file.additions, 3)
        XCTAssertEqual(file.hunks[0].lines.map(\.text), ["line1", "line2", "line3"])
    }

    func testParsesPatchWithCRLFContent() {
        let patch = "diff --git a/crlf.csv b/crlf.csv\n"
            + "new file mode 100644\n"
            + "index 0000000..1111111\n"
            + "--- /dev/null\n"
            + "+++ b/crlf.csv\n"
            + "@@ -0,0 +1,3 @@\n"
            + "+line1\r\n"
            + "+line2\r\n"
            + "+line3\r\n"

        let files = PatchParser.parse(patch)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].hunks.count, 1)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines.map(\.text), ["line1", "line2", "line3"])
        XCTAssertTrue(lines.allSatisfy { $0.kind == .addition })
    }

    func testUntrackedFileDiffMarksBinary() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]).write(
            to: dir.appendingPathComponent("img.png")
        )

        let file = try XCTUnwrap(
            DiffComputer.untrackedFileDiff(path: "img.png", worktreePath: dir.path)
        )
        XCTAssertTrue(file.isBinary)
        XCTAssertEqual(file.additions, 0)
        XCTAssertTrue(file.hunks.isEmpty)
    }

    func testUntrackedFileDiffEmptyAndMissingFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("empty.txt"))

        let empty = try XCTUnwrap(
            DiffComputer.untrackedFileDiff(path: "empty.txt", worktreePath: dir.path)
        )
        XCTAssertEqual(empty.additions, 0)
        XCTAssertTrue(empty.hunks.isEmpty)
        XCTAssertFalse(empty.isBinary)

        XCTAssertNil(DiffComputer.untrackedFileDiff(path: "gone.txt", worktreePath: dir.path))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetline-difftest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testWorktreeSlug() {
        XCTAssertEqual(WorktreeOps.slug("Fix the API!! v2"), "fix-the-api-v2")
        XCTAssertEqual(WorktreeOps.slug(""), "workspace")
        XCTAssertEqual(WorktreeOps.slug("////"), "workspace")
    }
}
