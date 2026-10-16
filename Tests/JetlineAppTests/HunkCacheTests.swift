import XCTest
@testable import JetlineApp

final class HunkCacheTests: XCTestCase {
    private func key(_ i: Int) -> HunkCache.Key { HunkCache.Key(oldSHA: "a", newSHA: "stat:\(i)") }

    /// ~3 MB of line text: about twenty fit the 64 MB budget.
    private let value = HunkCache.Value(
        hunks: [FileDiff.Hunk(header: "@@", lines: [FileDiff.Line(kind: .addition, text: String(repeating: "x", count: 3 << 20))])],
        isBinary: false
    )

    func testEvictsLeastRecentlyUsedPastByteBudget() async {
        let cache = HunkCache()
        await cache.set((0..<20).map { (key($0), value) })
        _ = await cache.get([key(0)])
        await cache.set((20..<25).map { (key($0), value) })

        let hits = await cache.get((0..<25).map(key)).map { $0 != nil }
        XCTAssertTrue(hits[0], "recently read entry survives")
        XCTAssertFalse(hits[1], "oldest unread entry is evicted")
        XCTAssertTrue(hits[24])
        XCTAssertLessThanOrEqual(hits.filter { $0 }.count, 21)
    }

    func testSkipsOversizedEntry() async {
        let cache = HunkCache()
        let huge = HunkCache.Value(
            hunks: [FileDiff.Hunk(header: "@@", lines: [FileDiff.Line(kind: .addition, text: String(repeating: "x", count: 5 << 20))])],
            isBinary: false
        )
        await cache.set([(key(0), huge)])
        let hit = await cache.get([key(0)])
        XCTAssertNil(hit[0] ?? nil)
    }

    func testWithoutHunksKeepsSummary() {
        let snap = DiffSnapshot(
            files: [FileDiff(path: "a", status: .modified, additions: 2, deletions: 1, hunks: value.hunks)],
            totalAdditions: 2,
            totalDeletions: 1
        )
        let stripped = snap.withoutHunks
        XCTAssertEqual(stripped.files.map(\.path), ["a"])
        XCTAssertEqual(stripped.files[0].additions, 2)
        XCTAssertTrue(stripped.files[0].hunks.isEmpty)
        XCTAssertEqual(stripped.totalAdditions, 2)
    }
}
