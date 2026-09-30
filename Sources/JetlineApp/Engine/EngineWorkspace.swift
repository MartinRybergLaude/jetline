import Foundation
import Observation

/// Per-workspace engine state: the git/PR picture the inspector shows and
/// everything running in the workspace. One per workspace that has any
/// state (PR snapshots exist for every workspace; the process-backed parts
/// only while the workspace is open).
///
/// `@Observable` so the server can publish just the part that changed —
/// its pumps read one field group each.
@MainActor
@Observable
final class EngineWorkspace {
    let id: String

    var diff: DiffSnapshot?
    var localDiff: DiffSnapshot?
    /// Tracked separately from the diff snapshots because porcelain status
    /// also flags untracked files, which `git diff` ignores.
    var hasUncommitted: Bool = false
    var pr: PRSnapshot = .loading
    /// PR comment stream, loaded on demand by `PRConversationStore`.
    var conversation: PRConversationSnapshot = .idle
    var branchPosition = BranchPosition()
    /// Pure-git action in flight (rebase, pull, merge).
    var runningGitAction: GitAction?
    var isTogglingAutoMerge: Bool = false
    /// A user-initiated PR refresh is awaiting the next poll.
    var isRefreshingPR: Bool = false
    /// Terminal tabs (agent TUIs and shells).
    var terminals: [EngineTerminal] = []
    /// Open chat tabs.
    var chats: [ChatEngine] = []
    var setup: ScriptRun?
    var run: ScriptRun?
    /// The runtime is up: activated and not closed since.
    var isOpen: Bool = false
    /// Set when auto-delete after the PR merged found local work.
    var keptAfterMerge: String?

    init(id: String) {
        self.id = id
    }

    /// Terminal tabs and chats — the tabs that keep a workspace open.
    var hasAgentTabs: Bool { !terminals.isEmpty || !chats.isEmpty }

    var diffState: WorkspaceDiffState {
        WorkspaceDiffState(diff: diff, localDiff: localDiff, hasUncommitted: hasUncommitted)
    }

    var status: WorkspaceStatus {
        WorkspaceStatus(
            branchPosition: branchPosition,
            runningGitAction: runningGitAction,
            isTogglingAutoMerge: isTogglingAutoMerge,
            isRefreshingPR: isRefreshingPR,
            terminals: terminals.map(\.info),
            chats: chats.map(\.summary),
            setup: setup?.info,
            run: run?.info,
            isOpen: isOpen,
            keptAfterMerge: keptAfterMerge
        )
    }
}

extension ChatEngine {
    var summary: ChatSummary {
        ChatSummary(id: id, provider: provider, title: title, activity: activity)
    }
}
