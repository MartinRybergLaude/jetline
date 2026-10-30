import XCTest
@testable import JetlineApp

@MainActor
final class DiffRefreshGateTests: XCTestCase {
    private let key = DiffCommitKey(head: "a1", base: "b1")

    func testUnknownWorkspaceCountsAsMoved() {
        XCTAssertTrue(DiffRefreshGate().commitsMoved(key, for: "ws"))
    }

    func testSameHashesAfterARefreshAreNotAMove() {
        let gate = DiffRefreshGate()
        gate.refreshed("ws", at: key)
        XCTAssertFalse(gate.commitsMoved(key, for: "ws"))
        XCTAssertTrue(gate.commitsMoved(DiffCommitKey(head: "a2", base: "b1"), for: "ws"), "a commit")
        XCTAssertTrue(gate.commitsMoved(DiffCommitKey(head: "a1", base: "b2"), for: "ws"), "the base moved")
    }

    func testUnresolvableHashesAlwaysRefresh() {
        let gate = DiffRefreshGate()
        gate.refreshed("ws", at: nil)
        XCTAssertTrue(gate.commitsMoved(nil, for: "ws"))
    }

    func testARefreshClearsPendingWrites() {
        let gate = DiffRefreshGate()
        gate.markPending("ws")
        gate.markPending("other")
        XCTAssertEqual(gate.pending, ["ws", "other"])
        gate.refreshStarted("ws")
        XCTAssertEqual(gate.pending, ["other"])
    }

    func testForgetDropsEverything() {
        let gate = DiffRefreshGate()
        gate.refreshed("ws", at: key)
        gate.markPending("ws")
        gate.forget("ws")
        XCTAssertTrue(gate.pending.isEmpty)
        XCTAssertTrue(gate.commitsMoved(key, for: "ws"))
    }

    func testWatcherTellsWorkingTreeFromGitDir() {
        let gitDirs = ["/repo/.git/worktrees/ws"]
        let index = "/repo/.git/worktrees/ws/index"
        typealias Change = WorktreeWatcher.Change
        XCTAssertEqual(WorktreeWatcher.change(touching: ["/wt/a.swift"], gitDirs: gitDirs), Change(workTree: true))
        XCTAssertEqual(WorktreeWatcher.change(touching: [index], gitDirs: gitDirs), Change(gitDir: true), "e.g. git status refreshing the index")
        XCTAssertEqual(WorktreeWatcher.change(touching: ["/wt/a.swift", index], gitDirs: gitDirs), .unknown)
        XCTAssertEqual(WorktreeWatcher.change(touching: [], gitDirs: gitDirs), .unknown, "a pathless tick could be anything")
    }

    func testCommitKeyMovesOnCommitsOnly() async throws {
        let repo = try await TestSupport.makeRepo()
        let firstKey = await DiffComputer.commitKey(worktreePath: repo, baseBranch: "main")
        let first = try XCTUnwrap(firstKey)

        try "edit\n".write(toFile: repo + "/README.md", atomically: true, encoding: .utf8)
        let afterWrite = await DiffComputer.commitKey(worktreePath: repo, baseBranch: "main")
        XCTAssertEqual(afterWrite, first, "a working-tree write moves no hash")

        _ = try await GitRunner.runChecked(["commit", "-qam", "edit"], cwd: repo)
        let afterCommitKey = await DiffComputer.commitKey(worktreePath: repo, baseBranch: "main")
        let afterCommit = try XCTUnwrap(afterCommitKey)
        XCTAssertNotEqual(afterCommit.head, first.head)

        let missingBase = await DiffComputer.commitKey(worktreePath: repo, baseBranch: "no-such-branch")
        XCTAssertNil(missingBase)
    }
}
