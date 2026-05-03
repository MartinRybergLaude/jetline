import XCTest
@testable import JetlineApp

final class GitActionStateTests: XCTestCase {
    func testEmptyDiffNoPRYieldsNoPrimary() {
        let state = GitActionState.derive(diff: .empty, pr: nil, hasUncommitted: false)
        XCTAssertNil(state.primary)
        for action in GitAction.allCases {
            XCTAssertFalse(state.isAvailable(action), "\(action) should be unavailable")
        }
    }

    func testCommitAvailableWhenWorkingTreeDirty() {
        // Branch is up to date with base (no diff vs base) but the working
        // tree has uncommitted edits — Commit must be the primary signal.
        let state = GitActionState.derive(diff: .empty, pr: .absent, hasUncommitted: true)
        XCTAssertEqual(state.primary, GitAction.commit)
        XCTAssertTrue(state.isAvailable(.commit))
        XCTAssertFalse(state.isAvailable(.review))
    }

    func testReviewAvailableWhenCommittedDivergence() {
        // Has diff vs base but working tree is clean — Create PR primary,
        // Review available alongside it.
        let state = GitActionState.derive(diff: nonEmptyDiff(), pr: .absent, hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.createPR)
        XCTAssertFalse(state.isAvailable(.commit))
        XCTAssertTrue(state.isAvailable(.review))
        XCTAssertTrue(state.isAvailable(.createPR))
    }

    func testBehindBaseSuggestsPullUpdates() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "BEHIND")
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.pullUpdates)
        XCTAssertTrue(state.isAvailable(.pullUpdates))
        XCTAssertFalse(state.isAvailable(.mergePR))
    }

    func testFailingChecksSuggestsFixCI() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "BLOCKED")
        let failing = CheckRun(
            name: "lint",
            status: .completed,
            conclusion: .failure,
            bucket: .fail
        )
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, [failing]), hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.fixCI)
        XCTAssertTrue(state.isAvailable(.fixCI))
        XCTAssertFalse(state.isAvailable(.fixComments))
        XCTAssertFalse(state.isAvailable(.mergePR))
    }

    func testUnresolvedThreadsSuggestsFixComments() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "BLOCKED", unresolved: 2)
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.fixComments)
        XCTAssertTrue(state.isAvailable(.fixComments))
    }

    func testTopLevelIssueCommentTriggersFixComments() {
        // Top-level PR comments don't create review threads — they go
        // through `comments`. Without this branch we'd miss them entirely.
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", issueComments: 1)
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.fixComments)
    }

    func testCleanReadyPRSuggestsMerge() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN")
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.mergePR)
        XCTAssertTrue(state.isAvailable(.mergePR))
    }

    func testCleanPRWithCommentsStillAllowsMerge() {
        // Comments are advisory on GitHub — they don't change mergeability.
        // Primary suggestion is fixComments (more thoughtful next step), but
        // mergePR stays available in the dropdown.
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", issueComments: 1)
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertEqual(state.primary, GitAction.fixComments)
        XCTAssertTrue(state.isAvailable(.mergePR))
    }

    func testDraftPRDoesNotSuggestMerge() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", isDraft: true)
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertNil(state.primary)
        XCTAssertFalse(state.isAvailable(.mergePR))
    }

    func testMergedPROffersNoPrimary() {
        let pr = makePR(state: "MERGED", mergeStateStatus: nil)
        let state = GitActionState.derive(diff: .empty, pr: .loaded(pr, []), hasUncommitted: false)
        XCTAssertNil(state.primary)
    }

    func testCommitWinsOverPRConcernsWhenWorkingTreeDirty() {
        // Branch has a stale PR open with failing CI, and the user has just
        // edited a file. Commit comes first — fix the local change before
        // re-engaging with the PR.
        let pr = makePR(state: "OPEN", mergeStateStatus: "BLOCKED")
        let failing = CheckRun(
            name: "lint",
            status: .completed,
            conclusion: .failure,
            bucket: .fail
        )
        let state = GitActionState.derive(
            diff: nonEmptyDiff(),
            pr: .loaded(pr, [failing]),
            hasUncommitted: true
        )
        XCTAssertEqual(state.primary, GitAction.commit)
        XCTAssertTrue(state.isAvailable(.fixCI))  // still in the dropdown
    }

    // MARK: - Helpers

    private func nonEmptyDiff() -> DiffSnapshot {
        DiffSnapshot(
            files: [FileDiff(path: "f.txt", status: .modified, additions: 1, deletions: 0, hunks: [])],
            totalAdditions: 1,
            totalDeletions: 0
        )
    }

    private func makePR(
        state: String,
        mergeStateStatus: String?,
        isDraft: Bool = false,
        unresolved: Int = 0,
        issueComments: Int = 0
    ) -> PullRequest {
        PullRequest(
            number: 42,
            title: "Test PR",
            url: "https://example.com/pr/42",
            state: state,
            isDraft: isDraft,
            headRefName: "feature/x",
            baseRefName: "main",
            author: PullRequest.Author(login: "tester"),
            mergeable: nil,
            mergeStateStatus: mergeStateStatus,
            unresolvedThreadCount: unresolved,
            issueCommentCount: issueComments
        )
    }
}

final class GitActionPromptsTests: XCTestCase {
    func testRenderInterpolatesWorkspaceFields() {
        let workspace = makeWorkspace(branch: "feature/x", base: "main")
        let rendered = GitActionPrompts.render(
            "Branch {branch} → {baseBranch}",
            workspace: workspace,
            pr: nil,
            checks: []
        )
        XCTAssertEqual(rendered, "Branch feature/x → main")
    }

    func testRenderEmptiesMissingPRPlaceholders() {
        let workspace = makeWorkspace(branch: "b", base: "main")
        let rendered = GitActionPrompts.render(
            "PR #{prNumber} {prTitle}",
            workspace: workspace,
            pr: nil,
            checks: []
        )
        XCTAssertEqual(rendered, "PR # ")
    }

    func testRenderListsCIFailures() {
        let workspace = makeWorkspace(branch: "b", base: "main")
        let failing = [
            CheckRun(name: "lint", status: .completed, conclusion: .failure, bucket: .fail, workflow: "CI"),
            CheckRun(name: "test", status: .completed, conclusion: .failure, bucket: .fail)
        ]
        let rendered = GitActionPrompts.render(
            "{ciFailures}",
            workspace: workspace,
            pr: nil,
            checks: failing
        )
        XCTAssertEqual(rendered, "CI / lint, test")
    }

    private func makeWorkspace(branch: String, base: String) -> Workspace {
        Workspace(
            id: "ws1",
            repositoryId: "repo1",
            name: "Test",
            branchName: branch,
            baseBranch: base,
            worktreePath: "/tmp/wt",
            agent: .claude,
            createdAt: Date(),
            lastActiveAt: Date()
        )
    }
}
