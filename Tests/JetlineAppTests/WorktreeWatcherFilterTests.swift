import XCTest
@testable import JetlineApp

final class WorktreeWatcherFilterTests: XCTestCase {
    private let gitDir = "/repo/.git"

    /// The branch poll's own `git fetch` rewrites FETCH_HEAD every time,
    /// even with nothing new. Firing on it refreshed the diff and kicked the
    /// PR tracker, which fetched again: the repo polled at its fastest rate
    /// for good, and the workspace never went idle.
    func testIgnoresWritesThatLeaveTheWorktreeAsItWas() {
        for path in [
            "/repo/.git/FETCH_HEAD",
            "/repo/.git/index.lock",
            "/repo/.git/HEAD.lock",
            "/repo/.git/objects/ab/cdef0123",
            "/repo/.git/logs/HEAD",
            "/repo/.git/worktrees/other/HEAD",
        ] {
            XCTAssertTrue(WorktreeWatcher.isGitDirNoise(path, gitDir: gitDir), path)
        }
    }

    func testKeepsWritesThatMoveHeadOrTheIndex() {
        for path in [
            "/repo/.git/HEAD",
            "/repo/.git/index",
            "/repo/.git/ORIG_HEAD",
            "/repo/.git/packed-refs",
            "/repo/.git/refs/heads/main",
            "/repo/.git/rebase-merge/done",
            "/repo/.git",
        ] {
            XCTAssertFalse(WorktreeWatcher.isGitDirNoise(path, gitDir: gitDir), path)
        }
    }
}
