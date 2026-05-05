import Foundation

/// Actions the user can trigger from the inspector's git action bar. All
/// except `mergePR` spawn a new agent tab with a prompt; merge runs
/// `gh pr merge` directly because the user explicitly wants merging to stay
/// out of the agent's hands.
enum GitAction: String, CaseIterable, Hashable {
    case commit
    case createPR
    case pullUpdates
    case rebaseOnMain
    case fixCI
    case fixComments
    case mergePR
    case review

    var displayName: String {
        switch self {
        case .commit:        return "Commit"
        case .createPR:      return "Create PR"
        case .pullUpdates:   return "Pull updates"
        case .rebaseOnMain:  return "Rebase"
        case .fixCI:         return "Fix CI"
        case .fixComments:   return "Fix comments"
        case .mergePR:       return "Merge PR"
        case .review:        return "Review"
        }
    }

    var systemImage: String {
        switch self {
        case .commit:        return "square.and.pencil"
        case .createPR:      return "arrow.triangle.pull"
        case .pullUpdates:   return "arrow.down.to.line"
        case .rebaseOnMain:  return "arrow.triangle.2.circlepath"
        case .fixCI:         return "exclamationmark.arrow.triangle.2.circlepath"
        case .fixComments:   return "text.bubble"
        case .mergePR:       return "arrow.triangle.merge"
        case .review:        return "text.magnifyingglass"
        }
    }

    /// True for actions that spawn an agent tab. False only for `mergePR`,
    /// which the app executes directly.
    var isAgentTask: Bool { self != .mergePR }

    /// Whether this action uses `AppSettings.reviewAgent` instead of
    /// `gitAgent`. Currently just `.review`.
    var usesReviewAgent: Bool { self == .review }

    /// Cases that have an editable prompt template. `mergePR` is excluded
    /// because it doesn't spawn an agent. Single source of truth for the
    /// settings-tab and per-repo-overrides-sheet iteration.
    static let promptable: [GitAction] = [
        .commit, .createPR, .pullUpdates, .rebaseOnMain, .fixCI, .fixComments, .review
    ]

    /// KeyPath into `AppSettings` for this action's prompt override. `nil`
    /// for `mergePR`. Consolidates what would otherwise be the same 7-arm
    /// switch in four places (settings/repo storage + their two binding
    /// helpers in the settings views).
    var settingsKeyPath: WritableKeyPath<AppSettings, String?>? {
        switch self {
        case .commit:        return \.commitPrompt
        case .createPR:      return \.createPRPrompt
        case .pullUpdates:   return \.pullUpdatesPrompt
        case .rebaseOnMain:  return \.rebaseOnMainPrompt
        case .fixCI:         return \.fixCIPrompt
        case .fixComments:   return \.fixCommentsPrompt
        case .review:        return \.reviewPrompt
        case .mergePR:       return nil
        }
    }

    /// KeyPath into `Repository` for the per-repo prompt override.
    var repositoryKeyPath: WritableKeyPath<Repository, String?>? {
        switch self {
        case .commit:        return \.commitPrompt
        case .createPR:      return \.createPRPrompt
        case .pullUpdates:   return \.pullUpdatesPrompt
        case .rebaseOnMain:  return \.rebaseOnMainPrompt
        case .fixCI:         return \.fixCIPrompt
        case .fixComments:   return \.fixCommentsPrompt
        case .review:        return \.reviewPrompt
        case .mergePR:       return nil
        }
    }
}
