import XCTest
@testable import JetlineApp

final class GitActionStateTests: XCTestCase {
    func testEmptyDiffNoPRYieldsNoPrimary() {
        let state = GitActionState.derive(
            diff: .empty,
            pr: nil,
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertNil(state.primary)
        for action in GitAction.allCases {
            XCTAssertFalse(state.isAvailable(action), "\(action) should be unavailable")
        }
    }

    func testCommitAvailableWhenWorkingTreeDirty() {
        // Branch is up to date with base (no diff vs base) but the working
        // tree has uncommitted edits — Commit must be the primary signal.
        let state = GitActionState.derive(
            diff: .empty,
            pr: .absent,
            hasUncommitted: true,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.commit)
        XCTAssertTrue(state.isAvailable(.commit))
        XCTAssertFalse(state.isAvailable(.review))
    }

    func testReviewAvailableWhenCommittedDivergence() {
        // Has diff vs base but working tree is clean — Create PR primary,
        // Review available alongside it.
        let state = GitActionState.derive(
            diff: nonEmptyDiff(),
            pr: .absent,
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.createPR)
        XCTAssertFalse(state.isAvailable(.commit))
        XCTAssertTrue(state.isAvailable(.review))
        XCTAssertTrue(state.isAvailable(.createPR))
    }

    func testRemoteHasNewCommitsSuggestsPullUpdates() {
        // Pull-updates is now driven by the local BranchPosition, not by
        // GitHub's mergeStateStatus — only the local fetch knows whether
        // origin/<branch> has commits we don't.
        let pr = makePR(state: "OPEN", mergeStateStatus: "OPEN")
        let position = BranchPosition(
            behindRemote: 2,
            aheadOfRemote: 0,
            behindBase: 0,
            remoteTrackingExists: true
        )
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: position
        )
        XCTAssertEqual(state.primary, GitAction.pullUpdates)
        XCTAssertTrue(state.isAvailable(.pullUpdates))
    }

    func testFailingChecksSuggestsFixCI() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "BLOCKED")
        let failing = CheckRun(
            name: "lint",
            status: .completed,
            conclusion: .failure,
            bucket: .fail
        )
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, [failing]),
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.fixCI)
        XCTAssertTrue(state.isAvailable(.fixCI))
        XCTAssertFalse(state.isAvailable(.fixComments))
    }

    func testUnresolvedThreadsSuggestsFixComments() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "BLOCKED", unresolved: 2)
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.fixComments)
        XCTAssertTrue(state.isAvailable(.fixComments))
    }

    func testTopLevelIssueCommentTriggersFixComments() {
        // Top-level PR comments don't create review threads — they go
        // through `comments`. Without this branch we'd miss them entirely.
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", issueComments: 1)
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.fixComments)
    }

    func testCleanReadyPRSuggestsMerge() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN")
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.mergePR)
        XCTAssertTrue(state.isAvailable(.mergePR))
    }

    func testCleanPRWithCommentsStillAllowsMerge() {
        // Comments are advisory on GitHub — they don't change mergeability.
        // Primary suggestion is fixComments (more thoughtful next step), but
        // mergePR stays available in the dropdown.
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", issueComments: 1)
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.fixComments)
        XCTAssertTrue(state.isAvailable(.mergePR))
    }

    func testDraftPRDoesNotSuggestMerge() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", isDraft: true)
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: nil
        )
        XCTAssertNil(state.primary)
        XCTAssertFalse(state.isAvailable(.mergePR))
    }

    func testMergedPROffersNoPrimary() {
        let pr = makePR(state: "MERGED", mergeStateStatus: nil)
        let state = GitActionState.derive(
            diff: .empty,
            pr: .loaded(pr, []),
            hasUncommitted: false,
            branchPosition: nil
        )
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
            hasUncommitted: true,
            branchPosition: nil
        )
        XCTAssertEqual(state.primary, GitAction.commit)
        XCTAssertTrue(state.isAvailable(.fixCI))  // still in the dropdown
    }

    // MARK: - gitHubAllowsMerge (shared toolbar + PR panel merge gate)

    func testAllowsMergeWhenOpenAndUnblocked() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED")
        XCTAssertTrue(GitActionState.gitHubAllowsMerge(pr))
    }

    func testAllowsMergeWithoutAnyReviewRequirement() {
        // `nil` reviewDecision = no branch protection. GitHub's own button
        // is live here, so ours is too.
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN")
        XCTAssertTrue(GitActionState.gitHubAllowsMerge(pr))
    }

    func testBlocksMergeWhenGitHubReportsBehind() {
        // BEHIND is only reported when the base branch requires up-to-date
        // branches — GitHub swaps its merge button for "Update branch", so
        // ours can't be live either.
        let pr = makePR(state: "OPEN", mergeStateStatus: "BEHIND", reviewDecision: "APPROVED")
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(pr))
    }

    func testBlocksMergeWhenBranchProtectionSaysBlocked() {
        // The bug this gate exists for: "all conversations must be resolved"
        // shows up only as BLOCKED — review is approved and the PR is
        // mergeable, so every other signal says go.
        let pr = makePR(
            state: "OPEN",
            mergeStateStatus: "BLOCKED",
            unresolved: 3,
            mergeable: "MERGEABLE",
            reviewDecision: "APPROVED"
        )
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(pr))
    }

    func testBlocksMergeWhileMergeabilityIsStillUnknown() {
        // UNKNOWN is what GitHub says before it has computed anything, not
        // a green light — see MergeReadinessTests.
        let pr = makePR(state: "OPEN", mergeStateStatus: "UNKNOWN", reviewDecision: "APPROVED")
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(pr))
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(
            makePR(state: "OPEN", mergeStateStatus: nil, reviewDecision: "APPROVED")
        ))
    }

    func testAllowsMergeWithFailingNonRequiredChecks() {
        // UNSTABLE = something red that isn't a required check. Mergeable.
        let pr = makePR(state: "OPEN", mergeStateStatus: "UNSTABLE", reviewDecision: "APPROVED")
        XCTAssertTrue(GitActionState.gitHubAllowsMerge(pr))
    }

    func testBlocksMergeWhenReviewRequiredOrChangesRequested() {
        for decision in ["REVIEW_REQUIRED", "CHANGES_REQUESTED"] {
            let pr = makePR(state: "OPEN", mergeStateStatus: "BLOCKED", reviewDecision: decision)
            XCTAssertFalse(GitActionState.gitHubAllowsMerge(pr), "\(decision) should block merge")
        }
    }

    func testBlocksMergeWhenConflictingDraftOrClosed() {
        let conflicting = makePR(
            state: "OPEN", mergeStateStatus: "DIRTY", mergeable: "CONFLICTING", reviewDecision: "APPROVED"
        )
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(conflicting))

        let draft = makePR(
            state: "OPEN", mergeStateStatus: "CLEAN", isDraft: true, reviewDecision: "APPROVED"
        )
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(draft))

        let merged = makePR(state: "MERGED", mergeStateStatus: nil, reviewDecision: "APPROVED")
        XCTAssertFalse(GitActionState.gitHubAllowsMerge(merged))
    }

    func testAvailabilityMatchesTheSharedGate() {
        let pr = makePR(state: "OPEN", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED")
        let state = GitActionState.derive(
            diff: .empty, pr: .loaded(pr, [check(.fail)]), hasUncommitted: false, branchPosition: nil
        )
        XCTAssertEqual(state.isAvailable(.mergePR), GitActionState.gitHubAllowsMerge(pr))
    }

    // MARK: - Helpers

    private func check(_ bucket: CheckBucket) -> CheckRun {
        CheckRun(
            name: bucket == .fail ? "lint" : "build",
            status: .completed,
            conclusion: bucket == .fail ? .failure : .success,
            bucket: bucket
        )
    }


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
        issueComments: Int = 0,
        mergeable: String? = nil,
        reviewDecision: String? = nil
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
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            unresolvedThreadCount: unresolved,
            issueCommentCount: issueComments,
            reviewDecision: reviewDecision
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
