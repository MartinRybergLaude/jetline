import XCTest
@testable import JetlineApp

final class WorktreeNamerTests: XCTestCase {
    func testStarNamesAreUniqueAndPathSafe() {
        let names = WorktreeNamer.starNames
        XCTAssertEqual(names.count, Set(names).count, "duplicate star names")
        for name in names {
            XCTAssertFalse(name.isEmpty)
            XCTAssertLessThanOrEqual(name.count, 9, "\(name) too long")
            XCTAssertTrue(
                name.allSatisfy { $0.isLowercase && $0.isASCII && $0.isLetter },
                "\(name) must be lowercase ascii letters only"
            )
        }
    }

    func testAllocateSkipsExistingDirectories() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("namer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // Occupy every star name except one; allocate must find the hole.
        let free = WorktreeNamer.starNames[7]
        for name in WorktreeNamer.starNames where name != free {
            try FileManager.default.createDirectory(
                at: folder.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }
        XCTAssertEqual(WorktreeNamer.allocate(in: folder), free)

        // Exhaust it too — fallback must produce an unused suffixed name.
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(free),
            withIntermediateDirectories: true
        )
        let fallback = WorktreeNamer.allocate(in: folder)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(fallback).path)
        )
        XCTAssertTrue(fallback.contains("-2"), "expected suffixed fallback, got \(fallback)")
    }

    func testAllocateOnMissingFolderReturnsAName() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("namer-missing-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(WorktreeNamer.starNames.contains(WorktreeNamer.allocate(in: folder)))
    }
}
