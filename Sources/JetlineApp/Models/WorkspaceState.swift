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
    /// PR comment stream. Loaded on demand by `PRConversationStore` while
    /// the PR tab is open — never by `PRTracker`, whose batched poll
    /// covers every workspace in every repo and would carry every comment
    /// body on every tick.
    var conversation: PRConversationSnapshot = .idle
    /// Local ahead/behind state, refreshed by `PRTracker` on each poll.
    /// Drives availability of `Pull updates` and `Rebase`.
    var branchPosition: BranchPosition = BranchPosition()
    /// Pure-git action currently in flight (rebase, pull, merge). The
    /// toolbar reads this to swap the git action button for a spinner.
    var runningGitAction: GitAction?
    /// True while an auto-merge enable/cancel is in flight. Separate from
    /// `runningGitAction`, which the toolbar reads to swap the git action
    /// button — queueing an auto-merge isn't a git action, it's a state
    /// change on the PR.
    var isTogglingAutoMerge: Bool = false
    /// True while a user-initiated PR refresh is awaiting the next poll.
    /// Drives the inspector's spinner.
    var isRefreshingPR: Bool = false
    var sessions: [PTYSession] = []
    /// Full-file diff tabs opened from the inspector's changes panel. They
    /// share the tab strip with the sessions but live apart from them —
    /// a diff tab has no process behind it.
    var diffTabs: [DiffTab] = []
    /// Native chats (the chat-UI alternative to agent TUI sessions). They
    /// survive relaunches: open chats are restored from the database the
    /// first time the workspace is activated.
    var chats: [ChatSession] = []
    /// The tab the main area is showing. New-tab pages (`TabRef.launcher`)
    /// live only here and in `tabOrder`: nothing runs behind one.
    var activeTab: TabRef?
    /// Strip order across sessions and diff tabs, which the strip shows as
    /// one list. Every open, close and reorder in `AppState` keeps it in step
    /// with `sessions` and `diffTabs`.
    var tabOrder: [TabRef] = []
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

    /// Terminal sessions and chats — the tabs that keep a workspace open.
    var hasAgentTabs: Bool { !sessions.isEmpty || !chats.isEmpty }

    var activeChat: ChatSession? {
        guard case .chat(let id) = activeTab else { return nil }
        return chats.first { $0.id == id }
    }

    /// Put `tab` in the strip: in `replacing`'s place when that's in the
    /// strip, else at the end.
    func insertTab(_ tab: TabRef, replacing: TabRef? = nil) {
        if let replacing, let index = tabOrder.firstIndex(of: replacing) {
            tabOrder[index] = tab
        } else {
            tabOrder.append(tab)
        }
    }

    /// Drop `tab` from the strip. Returns the neighbour that takes over when
    /// it was the one showing: the tab after it, else the one before.
    func removeTab(_ tab: TabRef) -> TabRef? {
        guard let index = tabOrder.firstIndex(of: tab) else { return nil }
        tabOrder.remove(at: index)
        guard activeTab == tab else { return nil }
        activeTab = nil
        return index < tabOrder.count ? tabOrder[index] : tabOrder.last
    }
}

/// A tab in the main-area strip: an agent/shell session, a diff tab, a
/// native chat or a new-tab page.
enum TabRef: Hashable, Identifiable {
    case session(String)
    case diff(String)
    case chat(String)
    case launcher(String)

    var id: String {
        switch self {
        case .session(let id): return "session:" + id
        case .diff(let id):    return "diff:" + id
        case .chat(let id):    return "chat:" + id
        case .launcher(let id): return "launcher:" + id
        }
    }
}

/// One file's full diff, opened as a tab in the main area.
struct DiffTab: Identifiable, Hashable {
    var path: String
    /// Which comparison the tab shows — whatever the changes panel was set
    /// to when the file was opened.
    var mode: DiffMode

    /// One tab per file: reopening a file re-targets its tab instead of
    /// stacking a second one.
    var id: String { path }
}
