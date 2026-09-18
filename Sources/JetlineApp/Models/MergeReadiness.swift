import Foundation

/// Whether the merge button should be live, and — when it shouldn't — what
/// is holding the PR back.
///
/// Readiness is decided by GitHub's own verdict (`mergeStateStatus` plus the
/// review decision), never by a rule Jetline invents. `checks` only refines
/// the explanation; it can't change the answer. Otherwise we'd be running a
/// second, subtly-different branch-protection engine next to the real one —
/// which is how a green button ends up in front of a PR that `gh pr merge`
/// then refuses.
enum MergeReadiness: Equatable {
    case ready
    case blocked(Blocker)

    /// What's unmet. Typed rather than a string so the UI can ask whether
    /// waiting would help (auto-merge) instead of pattern-matching prose.
    enum Blocker: Equatable {
        case notOpen(state: String)
        case draft
        case conflicts(base: String)
        case changesRequested
        case reviewRequired
        case behind(base: String)
        case unresolvedConversations(Int)
        case requiredChecksFailing
        case requiredChecksRunning
        /// `BLOCKED` with nothing we can see to pin it on.
        case branchProtection
        /// GitHub hasn't computed mergeability yet. Transient: asking is
        /// what makes it compute, so the next poll has the real answer.
        case checking

        /// One short line for the footer caption. Each is a statement of
        /// fact rather than a claim about the repo's rules, so it stays
        /// true even when the blocker is really something else.
        var message: String {
            switch self {
            case let .notOpen(state):           return "Pull request is \(state)"
            case .draft:                        return "Marked as draft"
            case let .conflicts(base):          return "Conflicts with \(base)"
            case .changesRequested:             return "Changes requested"
            case .reviewRequired:               return "Review required"
            case let .behind(base):             return "Out of date with \(base)"
            case let .unresolvedConversations(n):
                return "\(n) unresolved conversation\(n == 1 ? "" : "s")"
            case .requiredChecksFailing:        return "Required checks failing"
            case .requiredChecksRunning:        return "Required checks still running"
            case .branchProtection:             return "Blocked by branch protection"
            case .checking:                     return "Checking mergeability…"
            }
        }

        /// Whether queueing an auto-merge makes sense here — i.e. whether
        /// this is something a later event (a review, a green check, a
        /// resolved thread) can clear on its own. GitHub hides its own
        /// auto-merge button for drafts, conflicts and closed PRs, which
        /// need a human before anything else can happen.
        var allowsAutoMerge: Bool {
            switch self {
            // `.checking` resolves in a second or two — offering to queue a
            // merge for a state we're about to learn would just be noise.
            case .notOpen, .draft, .conflicts, .checking:
                return false
            case .changesRequested, .reviewRequired, .behind,
                 .unresolvedConversations, .requiredChecksFailing,
                 .requiredChecksRunning, .branchProtection:
                return true
            }
        }

        /// SF Symbol for the footer caption. Only `.checking` is a normal
        /// part of loading rather than something in the user's way.
        var symbol: String {
            self == .checking ? "arrow.triangle.2.circlepath" : "exclamationmark.circle"
        }
    }

    var isReady: Bool { self == .ready }

    var blocker: Blocker? {
        if case let .blocked(blocker) = self { return blocker }
        return nil
    }

    var reason: String? { blocker?.message }

    static func evaluate(pr: PullRequest, checks: [CheckRun] = []) -> MergeReadiness {
        guard pr.state.uppercased() == "OPEN" else {
            return .blocked(.notOpen(state: pr.state.lowercased()))
        }
        if pr.isDraft || pr.mergeState == .draft {
            return .blocked(.draft)
        }
        if pr.mergeable?.uppercased() == "CONFLICTING" || pr.mergeState == .dirty {
            return .blocked(.conflicts(base: pr.baseRefName))
        }
        switch pr.reviewState {
        case .changesRequested: return .blocked(.changesRequested)
        case .reviewRequired:   return .blocked(.reviewRequired)
        case .approved, .unreviewed: break
        }
        if pr.mergeState == .unknown {
            // Nothing GitHub told us can be trusted yet — `mergeable` is
            // `UNKNOWN` alongside it — so don't hand over a live merge
            // button on the strength of the fields that did arrive.
            return .blocked(.checking)
        }
        if pr.mergeState == .behind {
            // Only reported when the base branch requires up-to-date
            // branches — GitHub replaces its merge button with "Update
            // branch" here, so we can't merge either.
            return .blocked(.behind(base: pr.baseRefName))
        }
        if pr.mergeState == .blocked {
            // `BLOCKED` doesn't say *which* rule is unmet, so name the most
            // likely unmet thing we can actually see.
            if pr.unresolvedThreadCount > 0 {
                return .blocked(.unresolvedConversations(pr.unresolvedThreadCount))
            }
            if checks.contains(where: { $0.bucket == .fail }) {
                return .blocked(.requiredChecksFailing)
            }
            if checks.contains(where: \.isActive) {
                return .blocked(.requiredChecksRunning)
            }
            return .blocked(.branchProtection)
        }
        return .ready
    }
}

extension PullRequest {
    /// Parsed `mergeStateStatus`. The raw strings come from GitHub's
    /// `MergeStateStatus` enum.
    enum MergeState: Sendable, Hashable {
        case clean, unstable, hasHooks, blocked, behind, dirty, draft, unknown

        init(raw: String?) {
            switch raw?.uppercased() {
            case "CLEAN":     self = .clean
            case "UNSTABLE":  self = .unstable
            case "HAS_HOOKS": self = .hasHooks
            case "BLOCKED":   self = .blocked
            case "BEHIND":    self = .behind
            case "DIRTY":     self = .dirty
            case "DRAFT":     self = .draft
            default:          self = .unknown
            }
        }

        /// Whether GitHub's own merge button is live in this state.
        ///
        /// `UNSTABLE` is a non-required check failing and `HAS_HOOKS` is a
        /// pre-receive hook repo — both merge fine.
        ///
        /// `UNKNOWN` (also what a missing field decodes to) is not an
        /// answer: GitHub computes mergeability lazily, and a PR that has
        /// been left alone for a while reports `UNKNOWN` on the first query
        /// and its real state on the next one. Treating it as mergeable is
        /// how an approved-but-blocked PR gets a live merge button, so it
        /// waits — `PRPanel` re-asks, which is what makes GitHub compute it.
        var allowsMerge: Bool {
            switch self {
            case .clean, .unstable, .hasHooks:                    return true
            case .blocked, .behind, .dirty, .draft, .unknown:     return false
            }
        }
    }

    var mergeState: MergeState { MergeState(raw: mergeStateStatus) }
}
