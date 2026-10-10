import XCTest
@testable import JetlineApp

final class WorkspaceStacksTests: XCTestCase {
    // main ← a ← b ← c, and d on main.
    private lazy var a = ws("a", base: "main")
    private lazy var b = ws("b", base: "a")
    private lazy var c = ws("c", base: "origin/b")
    private lazy var d = ws("d", base: "origin/main")
    private let repo = Repository(
        id: "repo", name: "repo", path: "/tmp/repo", defaultBranch: "main",
        createdAt: Date(timeIntervalSince1970: 0)
    )

    func testParentMatchesLocalAndRemoteBase() {
        let all = [a, b, c, d]
        XCTAssertNil(WorkspaceStacks.parent(of: a, in: all, repo: repo))
        XCTAssertEqual(WorkspaceStacks.parent(of: b, in: all, repo: repo)?.id, "a")
        XCTAssertEqual(WorkspaceStacks.parent(of: c, in: all, repo: repo)?.id, "b")
    }

    func testSidebarOrderPutsLayersUnderTheirBase() {
        // List order puts children first, as new workspaces land at the top.
        let order = WorkspaceStacks.sidebarOrder([c, d, b, a], repo: repo)
        XCTAssertEqual(order.map(\.workspace.id), ["d", "a", "b", "c"])
        XCTAssertEqual(order.map(\.depth), [0, 0, 1, 2])
    }

    func testSidebarOrderSurvivesACycle() {
        let x = ws("x", base: "y")
        let y = ws("y", base: "x")
        let order = WorkspaceStacks.sidebarOrder([x, y], repo: repo)
        XCTAssertEqual(Set(order.map(\.workspace.id)), ["x", "y"])
    }

    func testReorderMovesAWholeStack() {
        // Sidebar: d, a, b, c. Moving stack a to the top.
        let ids = WorkspaceStacks.reorder([d, a, b, c], moving: "a", toGap: 0, repo: repo)
        XCTAssertEqual(ids, ["a", "b", "c", "d"])
        // Moving d to the end (gap 4).
        let back = WorkspaceStacks.reorder([d, a, b, c], moving: "d", toGap: 4, repo: repo)
        XCTAssertEqual(back, ["a", "b", "c", "d"])
    }

    func testReorderIntoAStackLandsAfterIt() {
        let ids = WorkspaceStacks.reorder([d, a, b, c], moving: "d", toGap: 2, repo: repo)
        XCTAssertEqual(ids, ["a", "b", "c", "d"])
    }

    func testUngroupedSidebarOrderKeepsListOrderFlat() {
        let order = WorkspaceStacks.sidebarOrder([c, d, b, a], repo: repo, grouped: false)
        XCTAssertEqual(order.map(\.workspace.id), ["c", "d", "b", "a"])
        XCTAssertEqual(order.map(\.depth), [0, 0, 0, 0])
    }

    func testUngroupedReorderMovesOneWorkspace() {
        // Grouped, moving a would carry b and c along; flat, it moves alone.
        let ids = WorkspaceStacks.reorder([d, a, b, c], moving: "a", toGap: 4, repo: repo, grouped: false)
        XCTAssertEqual(ids, ["d", "b", "c", "a"])
    }

    func testLocalStackSummary() throws {
        let all = [a, b, c, d]
        let summary = try XCTUnwrap(StackSummary.build(for: b, in: all, repo: repo) { _ in nil })
        XCTAssertEqual(summary.layers.map(\.id), ["c", "b", "a"])
        XCTAssertEqual(summary.layers.map(\.isCurrent), [false, true, false])
        XCTAssertEqual(summary.trunk, "main")
        XCTAssertFalse(summary.isOnGitHub)
    }

    func testNoSummaryOutsideAStack() {
        XCTAssertNil(StackSummary.build(for: d, in: [a, b, d], repo: repo) { _ in nil })
    }

    func testGitHubStackSummaryAddsLocalLayersAbove() throws {
        let stack = PRStack(
            number: 7,
            baseRefName: "main",
            position: 2,
            entries: [
                entry(1, number: 10, head: "a", state: "MERGED"),
                entry(2, number: 11, head: "b", state: "OPEN")
            ]
        )
        let prs = ["b": pr(11, head: "b", base: "a", stack: stack)]
        let summary = try XCTUnwrap(StackSummary.build(for: b, in: [a, b, c], repo: repo) { prs[$0.id] })
        XCTAssertTrue(summary.isOnGitHub)
        XCTAssertEqual(summary.layers.map(\.branch), ["c", "b", "a"])
        XCTAssertEqual(summary.layers.map(\.number), [nil, 11, 10])
        XCTAssertEqual(summary.layers[1].workspaceId, "b")
    }

    func testBaseRefIsLocalOnlyWhenStacked() {
        let all = [a, b, d]
        XCTAssertEqual(WorkspaceStacks.baseRef(for: b, in: all, repo: repo), "a")
        XCTAssertEqual(WorkspaceStacks.baseRef(for: a, in: all, repo: repo), "origin/main")
        XCTAssertEqual(WorkspaceStacks.baseRef(for: d, in: all, repo: repo), "origin/main")
    }

    func testOpenEntriesBelow() {
        let stack = PRStack(
            number: 7,
            baseRefName: "main",
            position: 3,
            entries: [
                entry(1, number: 10, head: "a", state: "MERGED"),
                entry(2, number: 11, head: "b", state: "OPEN"),
                entry(3, number: 12, head: "c", state: "OPEN"),
                entry(4, number: 13, head: "e", state: "OPEN")
            ]
        )
        XCTAssertEqual(stack.openEntriesBelow.map(\.number), [11])
        XCTAssertFalse(stack.isTop)
        XCTAssertEqual(pr(12, head: "c", base: "b", stack: stack).mergedTogether, [11, 12])
    }

    func testStackMergesOnlyWhenEveryOpenLayerIsReady() {
        var ready = entry(2, number: 11, head: "b", state: "OPEN")
        ready.mergeable = "MERGEABLE"
        ready.mergeStateStatus = "CLEAN"
        var blocked = entry(3, number: 12, head: "c", state: "OPEN")
        blocked.mergeable = "MERGEABLE"
        blocked.mergeStateStatus = "BLOCKED"
        blocked.reviewDecision = "REVIEW_REQUIRED"
        let merged = entry(1, number: 10, head: "a", state: "MERGED")

        var stack = PRStack(number: 7, baseRefName: "main", position: 3, entries: [merged, ready, blocked])
        XCTAssertFalse(stack.mergeAll.ready)
        XCTAssertEqual(stack.mergeAll.blocking?.number, 12)
        XCTAssertEqual(stack.mergeAll.blocking?.reason, "Review required")

        blocked.mergeStateStatus = "CLEAN"
        blocked.reviewDecision = "APPROVED"
        stack.entries = [merged, ready, blocked]
        XCTAssertTrue(stack.mergeAll.ready)
        XCTAssertEqual(stack.openEntries.map(\.number), [11, 12])
    }

    func testPullRequestRoundTripsStack() throws {
        let stack = PRStack(number: 7, baseRefName: "main", position: 1, entries: [entry(1, number: 10, head: "a", state: "OPEN")])
        let original = pr(10, head: "a", base: "main", stack: stack)
        let decoded = try JSONDecoder().decode(PullRequest.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.stack, stack)
    }

    // MARK: - Helpers

    private func ws(_ branch: String, base: String) -> Workspace {
        Workspace(
            id: branch,
            repositoryId: "repo",
            name: branch.uppercased(),
            branchName: branch,
            baseBranch: base,
            worktreePath: "/tmp/\(branch)",
            agent: .claude,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func entry(_ position: Int, number: Int, head: String, state: String) -> PRStack.Entry {
        PRStack.Entry(position: position, number: number, title: "PR \(number)", url: "https://example.com/\(number)",
                      state: state, isDraft: false, headRefName: head)
    }

    private func pr(_ number: Int, head: String, base: String, stack: PRStack?) -> PullRequest {
        PullRequest(
            number: number,
            title: "PR \(number)",
            url: "https://example.com/\(number)",
            state: "OPEN",
            isDraft: false,
            headRefName: head,
            baseRefName: base,
            author: PullRequest.Author(login: "tester"),
            stack: stack
        )
    }
}
