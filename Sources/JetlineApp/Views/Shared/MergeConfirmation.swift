import SwiftUI

/// Merge-method confirmation, shared by the toolbar's git action menu and
/// the PR panel's merge button. Both entry points have to offer the same
/// methods in the same order with the same default, and the rules for that
/// (repo-allowed methods, last-used wins, be permissive before metadata
/// lands) are easy to get subtly wrong twice.
struct MergeConfirmation: ViewModifier {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    /// The strategy to confirm. `nil` asks in the dialog itself (one button
    /// per allowed method) — what the toolbar's menu does, since it has
    /// nowhere to offer the choice up front.
    var method: MergeMethod?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.confirmationDialog(
            title,
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            if let method {
                Button(method.displayName) {
                    Task { await state.performMerge(for: workspace, method: method) }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel", role: .cancel) {}
            } else {
                methodButtons
            }
        } message: {
            Text("Merges PR for `\(workspace.branchName)` into `\(workspace.baseBranch)` immediately and pushes the result to the remote.")
        }
    }

    /// One button per allowed merge method, in GitHub's display order. The
    /// last-used method (if known) gets `.defaultAction` so Return triggers
    /// it.
    @ViewBuilder
    private var methodButtons: some View {
        let lastUsed = state.lastMergeMethod(for: workspace)
        ForEach(state.allowedMergeMethods(for: workspace), id: \.self) { method in
            Button(method.displayName) {
                Task { await state.performMerge(for: workspace, method: method) }
            }
            .keyboardShortcut(method == lastUsed ? .defaultAction : nil)
        }
        Button("Cancel", role: .cancel) {}
    }

    private var title: String {
        if case let .loaded(pr, _) = state.workspaceState(for: workspace.id).pr {
            return "Merge PR #\(pr.number)?"
        }
        return "Merge pull request?"
    }
}

extension View {
    func mergeConfirmation(
        workspace: Workspace,
        method: MergeMethod? = nil,
        isPresented: Binding<Bool>
    ) -> some View {
        modifier(MergeConfirmation(workspace: workspace, method: method, isPresented: isPresented))
    }
}
