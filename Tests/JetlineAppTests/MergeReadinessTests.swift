import XCTest
@testable import JetlineApp

final class MergeReadinessTests: XCTestCase {
    func testReadyWhenGitHubReportsClean() {
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: pr(mergeStateStatus: "CLEAN", reviewDecision: "APPROVED")),
            .ready
        )
    }

    func testReadyWithNonRequiredChecksFailing() {
        // UNSTABLE = something red that isn't a required check. GitHub
        // merges it, so the button stays live even with a red row above it.
        let failing = check(bucket: .fail)
        XCTAssertEqual(
            MergeReadiness.evaluate(
                pr: pr(mergeStateStatus: "UNSTABLE", reviewDecision: "APPROVED"),
                checks: [failing]
            ),
            .ready
        )
    }

    func testReadyWithPreReceiveHooks() {
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: pr(mergeStateStatus: "HAS_HOOKS", reviewDecision: "APPROVED")),
            .ready
        )
    }

    func testUncomputedMergeabilityWaitsRatherThanGoingGreen() {
        // GitHub answers UNKNOWN for a PR nobody has touched recently and
        // computes the real state for the next query. Trusting the fields
        // that *did* arrive is how an approved-but-blocked PR gets a live
        // merge button.
        for status in ["UNKNOWN", nil] {
            XCTAssertEqual(
                MergeReadiness.evaluate(pr: pr(mergeStateStatus: status, reviewDecision: "APPROVED")),
                .blocked(.checking),
                "\(status ?? "nil") should wait for a real answer"
            )
        }
        XCTAssertFalse(MergeReadiness.Blocker.checking.allowsAutoMerge)
    }

    func testUnresolvedConversationsAreNamedAsTheBlocker() {
        // The reported bug: branch protection requires every conversation
        // resolved. Review is approved, the PR is mergeable, and BLOCKED is
        // the only signal that anything is wrong.
        let blocked = pr(
            mergeStateStatus: "BLOCKED",
            mergeable: "MERGEABLE",
            reviewDecision: "APPROVED",
            unresolved: 3
        )
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: blocked),
            .blocked(.unresolvedConversations(3))
        )
    }

    func testSingleUnresolvedConversationIsSingular() {
        let blocked = pr(mergeStateStatus: "BLOCKED", reviewDecision: "APPROVED", unresolved: 1)
        XCTAssertEqual(MergeReadiness.evaluate(pr: blocked), .blocked(.unresolvedConversations(1)))
    }

    func testBlockedFallsBackToCheckStateThenProtection() {
        let blocked = pr(mergeStateStatus: "BLOCKED", reviewDecision: "APPROVED")

        XCTAssertEqual(
            MergeReadiness.evaluate(pr: blocked, checks: [check(bucket: .fail)]),
            .blocked(.requiredChecksFailing)
        )
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: blocked, checks: [running()]),
            .blocked(.requiredChecksRunning)
        )
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: blocked, checks: [check(bucket: .pass)]),
            .blocked(.branchProtection)
        )
    }

    func testReviewGateOutranksBranchProtectionInTheExplanation() {
        // Both are true when review is the unmet rule; "Review required" is
        // the actionable half.
        let blocked = pr(mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED", unresolved: 2)
        XCTAssertEqual(MergeReadiness.evaluate(pr: blocked), .blocked(.reviewRequired))

        let changes = pr(mergeStateStatus: "BLOCKED", reviewDecision: "CHANGES_REQUESTED")
        XCTAssertEqual(MergeReadiness.evaluate(pr: changes), .blocked(.changesRequested))
    }

    func testConflictsDraftAndBehindNameThemselves() {
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: pr(mergeStateStatus: "DIRTY", mergeable: "CONFLICTING")),
            .blocked(.conflicts(base: "main"))
        )
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: pr(mergeStateStatus: "DRAFT", isDraft: true)),
            .blocked(.draft)
        )
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: pr(mergeStateStatus: "BEHIND", reviewDecision: "APPROVED")),
            .blocked(.behind(base: "main"))
        )
    }

    func testClosedPRIsNeverReady() {
        XCTAssertEqual(
            MergeReadiness.evaluate(pr: pr(state: "MERGED", mergeStateStatus: nil)),
            .blocked(.notOpen(state: "merged"))
        )
    }


    // MARK: - Auto-merge

    func testAutoMergeIsOfferedForBlockersThatClearThemselves() {
        // Everything a review, a green check or a resolved thread can undo.
        let waitable: [MergeReadiness.Blocker] = [
            .reviewRequired, .changesRequested, .behind(base: "main"),
            .unresolvedConversations(2), .requiredChecksFailing,
            .requiredChecksRunning, .branchProtection,
        ]
        for blocker in waitable {
            XCTAssertTrue(blocker.allowsAutoMerge, "\(blocker) should offer auto-merge")
        }
    }

    func testAutoMergeIsNotOfferedWhereAHumanMustActFirst() {
        for blocker in [MergeReadiness.Blocker.draft, .conflicts(base: "main"), .notOpen(state: "closed"), .checking] {
            XCTAssertFalse(blocker.allowsAutoMerge, "\(blocker) should not offer auto-merge")
        }
    }

    func testBlockerMessagesReadAsFacts() {
        XCTAssertEqual(MergeReadiness.Blocker.unresolvedConversations(1).message, "1 unresolved conversation")
        XCTAssertEqual(MergeReadiness.Blocker.unresolvedConversations(4).message, "4 unresolved conversations")
        XCTAssertEqual(MergeReadiness.Blocker.behind(base: "develop").message, "Out of date with develop")
    }

    // MARK: - Helpers


    private func pr(
        state: String = "OPEN",
        mergeStateStatus: String?,
        isDraft: Bool = false,
        mergeable: String? = nil,
        reviewDecision: String? = nil,
        unresolved: Int = 0
    ) -> PullRequest {
        PullRequest(
            number: 1844,
            title: "Test PR",
            url: "https://example.com/pr/1844",
            state: state,
            isDraft: isDraft,
            headRefName: "feature/x",
            baseRefName: "main",
            author: PullRequest.Author(login: "tester"),
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            unresolvedThreadCount: unresolved,
            reviewDecision: reviewDecision
        )
    }

    private func check(bucket: CheckBucket) -> CheckRun {
        CheckRun(
            name: "build",
            status: .completed,
            conclusion: bucket == .fail ? .failure : .success,
            bucket: bucket
        )
    }

    private func running() -> CheckRun {
        CheckRun(name: "build", status: .inProgress, conclusion: .unknown, bucket: .pending)
    }
}
