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
        .fixCI,
        .fixComments,
        .mergePR,
        .createPR,
        .review
    ]

    static func derive(
        diff: DiffSnapshot?,
        pr: PRSnapshot?,
        hasUncommitted: Bool
    ) -> GitActionState {
        let hasDiffVsBase = !(diff?.isEmpty ?? true)

        var avail: [GitAction: Bool] = [:]
        for action in GitAction.allCases { avail[action] = false }

        avail[.commit] = hasUncommitted
        avail[.review] = hasDiffVsBase

        switch pr {
        case .loaded(let pull, let checks):
            let isOpen = pull.state.uppercased() == "OPEN"
            guard isOpen else { break }

            let mergeStatus = pull.mergeStateStatus?.uppercased()
            let isBehind = mergeStatus == "BEHIND"
            let isClean = mergeStatus == "CLEAN"
            let hasFailing = checks.contains { $0.bucket == .fail }
            let hasComments = pull.hasOpenComments

            avail[.pullUpdates] = isBehind
            avail[.fixCI] = hasFailing
            avail[.fixComments] = hasComments
            // Trust GitHub's `mergeStateStatus`. CLEAN already encodes
            // "required checks passed and approvals satisfied" — comments
            // and non-required failing checks don't block merging there, so
            // they shouldn't block it here either.
            avail[.mergePR] = isClean && !pull.isDraft

        case .absent:
            avail[.createPR] = hasDiffVsBase

        case .loading, .error, .none:
            break
        }

        let primary = priority.first { avail[$0] == true }
        return GitActionState(primary: primary, availability: avail)
    }
}
