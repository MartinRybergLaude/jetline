import XCTest
@testable import JetlineApp

final class DiffTreeTests: XCTestCase {
    private func file(_ path: String) -> FileDiff {
        FileDiff(path: path, status: .modified, additions: 0, deletions: 0, hunks: [])
    }

    private func describe(_ rows: [DiffTree.Row]) -> [String] {
        rows.map {
            switch $0 {
            case .folder(_, let name, let depth):
                return String(repeating: "  ", count: depth) + name + "/"
            case .file(let f, let depth):
                return String(repeating: "  ", count: depth) + (f.path as NSString).lastPathComponent
            }
        }
    }

    func testCompactsChainsAndSortsFoldersFirst() {
        let rows = DiffTree.rows(for: [
            file("apps/web/src/lib/b.ts"),
            file("apps/web/messages/en.json"),
            file("apps/web/src/lib/a/x.ts"),
            file("README.md"),
        ])
        XCTAssertEqual(describe(rows), [
            "apps/web/",
            "  messages/",
            "    en.json",
            "  src/lib/",
            "    a/",
            "      x.ts",
            "    b.ts",
            "README.md",
        ])
    }

    func testCollapsedFolderHidesContents() {
        let rows = DiffTree.rows(
            for: [file("a/b/c.ts"), file("a/d.ts")],
            collapsed: ["a/b"]
        )
        XCTAssertEqual(describe(rows), ["a/", "  b/", "  d.ts"])
    }
}

final class FileDiffLineTests: XCTestCase {
    #if os(macOS)
    func testNumbersLinesFromHunkHeader() {
        let file = FileDiff(path: "a.txt", status: .modified, additions: 1, deletions: 1, hunks: [
            .init(header: "@@ -3,3 +3,3 @@ func x()", lines: [
                .init(kind: .context, text: "a"),
                .init(kind: .deletion, text: "b"),
                .init(kind: .addition, text: "B"),
                .init(kind: .context, text: "c"),
            ])
        ])
        let rows = FileDiffLine.lines(for: file)
        XCTAssertEqual(rows.map(\.newNumber), [3, nil, 4, 5])
        XCTAssertFalse(rows.contains(where: \.isHunkHeader))
    }

    func testNewFileStartsAtOne() {
        XCTAssertEqual(FileDiffLine.newStartLine(ofHunkHeader: "@@ -0,0 +1,12 @@"), 1)
    }
    #endif
}
