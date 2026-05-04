import SwiftUI

/// Toolbar split-button for the workspace's git actions. Mirrors the
/// `OpenInAppButton` pattern: the body runs the algorithmically-chosen
/// primary action; the chevron exposes every other action as a menu item,
/// disabled when its preconditions aren't met.
///
/// All actions live in the dropdown so the user can read it like a status
/// report — what's actionable, what isn't, and why (via tooltip / disabled
/// state). Picking an unavailable item from the menu isn't possible, so
/// users can't accidentally spawn a no-op agent tab.
struct GitActionMenu: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    @State private var pendingMerge: Bool = false

    var body: some View {
        let actionState = GitActionState.derive(
            diff: state.diffByWorkspace[workspace.id],
            pr: state.prByWorkspace[workspace.id],
            hasUncommitted: state.hasUncommittedByWorkspace[workspace.id] ?? false,
            branchPosition: state.branchPositionByWorkspace[workspace.id]
        )

        menu(for: actionState)
            .help(helpText(for: actionState))
            .confirmationDialog(
                mergeConfirmTitle,
                isPresented: $pendingMerge,
                titleVisibility: .visible
            ) {
                mergeDialogButtons
            } message: {
                Text("Merges PR for `\(workspace.branchName)` into `\(workspace.baseBranch)` immediately and pushes the result to the remote.")
            }
    }

    /// One button per allowed merge method, in GitHub's display order. The
    /// last-used method (if known) gets `.defaultAction` so Return triggers
    /// it. Falls back to showing all three when the repo metadata hasn't
    /// loaded yet — we'd rather offer too many options than block the merge
    /// behind a freshly-launched app.
    @ViewBuilder
    private var mergeDialogButtons: some View {
        let allowed = state.repoMetadataByRepo[workspace.repositoryId]?.allowedMergeMethods
            ?? Set(MergeMethod.allCases)
        let lastUsed = state.lastMergeMethod(for: workspace)
        let methods = MergeMethod.displayOrder.filter { allowed.contains($0) }

        ForEach(methods, id: \.self) { method in
            Button(method.displayName) {
                Task { await state.performMerge(for: workspace, method: method) }
            }
            .keyboardShortcut(method == lastUsed ? .defaultAction : nil)
        }
        Button("Cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func menu(for s: GitActionState) -> some View {
        if let primary = s.primary {
            Menu {
                items(state: s, excluding: primary)
            } label: {
                label(for: primary)
            } primaryAction: {
                trigger(primary)
            }
            .menuIndicator(.visible)
        } else {
            // Nothing actionable — still show the button so the user can
            // open the dropdown and see *why*.
            Menu {
                items(state: s, excluding: nil)
            } label: {
                idleLabel
            }
            .menuIndicator(.visible)
        }
    }

    @ViewBuilder
    private func items(state: GitActionState, excluding primary: GitAction?) -> some View {
        ForEach(GitAction.allCases, id: \.self) { action in
            if action != primary {
                Button {
                    trigger(action)
                } label: {
                    Label(action.displayName, systemImage: action.systemImage)
                }
                .disabled(!state.isAvailable(action))
            }
        }
    }

    private func trigger(_ action: GitAction) {
        if action == .mergePR {
            pendingMerge = true
            return
        }
        state.startGitActionSession(for: workspace, action: action)
    }

    private func label(for action: GitAction) -> some View {
        HStack(spacing: 5) {
            Image(systemName: action.systemImage)
                .font(.system(size: 13))
                .frame(width: 14, height: 14)
            Text(action.displayName)
        }
    }

    private var idleLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 13))
                .frame(width: 14, height: 14)
            Text("Git")
        }
    }

    private var mergeConfirmTitle: String {
        if case let .loaded(pr, _) = state.prByWorkspace[workspace.id] {
            return "Merge PR #\(pr.number)?"
        }
        return "Merge pull request?"
    }

    private func helpText(for s: GitActionState) -> String {
        guard let primary = s.primary else {
            return "Git actions — nothing actionable right now"
        }
        switch primary {
        case .commit:        return "Commit uncommitted changes with the git agent"
        case .createPR:      return "Push and open a pull request"
        case .pullUpdates:   return "Pull commits from origin/\(workspace.branchName) (rebase)"
        case .rebaseOnMain:  return "Rebase this branch onto \(workspace.baseBranch)"
        case .fixCI:         return "Investigate and fix failing CI checks"
        case .fixComments:   return "Fix open PR comments"
        case .mergePR:       return "Merge the pull request"
        case .review:        return "Run a code review with the review agent"
        }
    }
}
