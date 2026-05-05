import Foundation

/// Pure derivation of which git actions are available for a workspace and
/// which is the suggested *primary* next step. Drives the toolbar's
/// adaptive split-button.
///
/// Every `GitAction` has an entry in `availability`. The primary is the
/// first by priority that's currently available (commit when there's a dirty
/// working tree, pullUpdates when behind, etc). When *nothing* is available,
/// `primary` is nil and the toolbar button stops offering a primary tap —
/// the dropdown still lets the user open the menu and see every option in a
/// disabled state, so they can read the bar like a status report.
struct GitActionState: Equatable {
    var primary: GitAction?
    var availability: [GitAction: Bool]

    static let empty = GitActionState(primary: nil, availability: [:])

    func isAvailable(_ action: GitAction) -> Bool {
        availability[action] ?? false
    }

    /// Priority order used to pick the primary suggestion. Pull updates
    /// first because being behind base makes everything downstream
    /// premature; commit at the top of the dirty-tree branch because you
    /// can't push or PR until you've committed.
    private static let priority: [GitAction] = [
        .commit,
        .pullUpdates,
        .rebaseOnMain,
        .fixCI,
        .fixComments,
        .mergePR,
        .createPR,
        .review
    ]

    static func derive(
        diff: DiffSnapshot?,
        pr: PRSnapshot?,
        hasUncommitted: Bool,
        branchPosition: BranchPosition?
    ) -> GitActionState {
        let hasDiffVsBase = !(diff?.isEmpty ?? true)

        var avail: [GitAction: Bool] = [:]
        for action in GitAction.allCases { avail[action] = false }

        avail[.commit] = hasUncommitted
        avail[.review] = hasDiffVsBase
        // Local git facts, independent of PR existence: pull-updates fires
        // when origin/<branch> has commits we don't; rebase-on-main fires
        // when the base has commits the branch doesn't.
        avail[.pullUpdates] = branchPosition?.remoteHasNewCommits ?? false
        avail[.rebaseOnMain] = branchPosition?.isBehindBase ?? false

        switch pr {
        case .loaded(let pull, let checks):
            let isOpen = pull.state.uppercased() == "OPEN"
            guard isOpen else { break }

            let hasFailing = checks.contains { $0.bucket == .fail }
            let hasComments = pull.hasOpenComments
            let conflicting = pull.mergeable?.uppercased() == "CONFLICTING"

            avail[.fixCI] = hasFailing
            avail[.fixComments] = hasComments
            // Merge gate: open + not draft + no conflicts + review not
            // blocking. `reviewDecision` is `nil` when the repo doesn't
            // require review, `APPROVED` once the required reviewers have
            // signed off, and `REVIEW_REQUIRED`/`CHANGES_REQUESTED` while
            // protection rules still block the merge — match what GitHub's
            // own merge button does. We stay permissive on `mergeStateStatus`
            // (UNSTABLE for non-required failing checks, UNKNOWN while it's
            // recomputing after a force-push) since those still mergeable.
            let reviewBlocks = pull.reviewDecision.map {
                let upper = $0.uppercased()
                return upper == "REVIEW_REQUIRED" || upper == "CHANGES_REQUESTED"
            } ?? false
            avail[.mergePR] = !conflicting && !pull.isDraft && !reviewBlocks

        case .absent:
            avail[.createPR] = hasDiffVsBase

        case .error:
            // Tracker couldn't determine PR state — don't strand the user.
            // `gh pr create` will reject a duplicate with a clear message,
            // so the worst case is a benign no-op the agent reports back.
            avail[.createPR] = hasDiffVsBase

        case .loading, .none:
            break
        }

        let primary = priority.first { avail[$0] == true }
        return GitActionState(primary: primary, availability: avail)
    }
}
