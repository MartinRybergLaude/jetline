import Foundation
import Observation

/// Per-workspace mutable state. Lives outside `AppState` so a single
/// workspace's PR snapshot, diff snapshot, branch position, etc. only
/// invalidates views that read that workspace — not every view in the app
/// via the shared observation surface. Without this split, each PRTracker
/// poll, FSEvents-driven diff refresh, and ahead/behind recompute would
/// invalidate the whole sidebar, the inspector, the terminal toolbar.
///
/// Uses the `Observation` macro so SwiftUI tracks reads per keypath:
/// a view that reads only `.pr` doesn't repaint when `.diff` changes,
/// and vice versa. Replacing the previous `ObservableObject` + `@Published`
/// surface (which kicked all observers on any change) is the second
/// half of the invalidation-narrowing story.
///
/// Lifecycle: created lazily by `AppState.workspaceState(for:)`, removed in
/// `detachWorkspace`. Owns no resources directly — sessions, run/setup
/// controllers, etc. live in slots and are torn down by `AppState` before
/// the state is discarded.
@MainActor
@Observable
final class WorkspaceState {
    let id: String

    var diff: DiffSnapshot?
    var localDiff: DiffSnapshot?
    /// Tracked separately from the diff snapshots because porcelain status
    /// also flags untracked files, which `git diff` ignores.
    var hasUncommitted: Bool = false
    var pr: PRSnapshot = .loading
    /// Local ahead/behind state, refreshed by `PRTracker` on each poll.
    /// Drives availability of `Pull updates` and `Rebase`.
    var branchPosition: BranchPosition = BranchPosition()
    /// Pure-git action currently in flight (rebase, pull, merge). The
    /// toolbar reads this to swap the git action button for a spinner.
    var runningGitAction: GitAction?
    /// True while a user-initiated PR refresh is awaiting the next poll.
    /// Drives the inspector's spinner.
    var isRefreshingPR: Bool = false
    var sessions: [PTYSession] = []
    var activeSessionId: String?
    /// Setup-script controller. Created when a fresh workspace spins up;
    /// lingers after exit so the user can scroll back through the log
    /// until they trigger a real run.
    var setupController: SetupController?
    /// Run-script controller. `nil` means "never run". Kept around after
    /// exit so the user can review the last log.
    var runController: RunController?

    init(id: String) {
        self.id = id
    }
}
