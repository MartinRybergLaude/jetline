#if os(macOS)
import SwiftUI

/// Top-level so `AppState` can drive selection from outside the view (e.g.
/// switch to `.run` when a fresh workspace's setup script kicks off).
enum InspectorTab: Hashable {
    case changes, pr, run

    /// A repository's base checkout has no branch of its own to open a PR
    /// from, so the PR tab would only ever spin.
    @MainActor
    static func available(in state: AppState) -> [InspectorTab] {
        if let id = state.inspectorWorkspaceId,
           let ws = state.workspaceById(id),
           state.isRepositoryBaseWorkspace(ws) {
            return [.changes, .run]
        }
        return [.changes, .pr, .run]
    }
}

/// Inspector view state that outlives any one inspector. Every native tab
/// window has its own inspector column, so what the user sets in one has to
/// be there when they switch tabs.
@MainActor
@Observable
final class InspectorUIState {
    var diffMode: DiffMode = .combined
    /// Folders collapsed in the changes tree, per workspace.
    var collapsedFolders: [String: Set<String>] = [:]
    var hideResolvedComments = false
}

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @Environment(InspectorUIState.self) private var ui

    /// The tab switcher lives in the column's top accessory
    /// (`InspectorTabsAccessory`), and the background is the inspector
    /// column's own — as in Xcode.
    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: InspectorTab.available(in: state), initial: true) { _, tabs in
                if !tabs.contains(state.inspectorTab) { state.inspectorTab = .changes }
            }
    }

    /// Every panel owns its scrolling: the file list scrolls inside its
    /// card, run output autoscrolls to the tail, the PR panel pins the
    /// merge footer.
    @ViewBuilder
    private var content: some View {
        switch state.inspectorTab {
        case .changes:
            VStack(spacing: 0) {
                DiffModeToggle(mode: Bindable(ui).diffMode)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ChangesPanel(mode: ui.diffMode)
                    .padding(.top, 8)
            }
        case .pr:
            // Owns its own scrolling: the merge button is pinned in a footer
            // the rest of the panel scrolls under.
            PRPanel()
        case .run:
            RunOutputPanel()
        }
    }
}

private struct DiffModeToggle: View {
    @Binding var mode: DiffMode

    private var isLocal: Binding<Bool> {
        Binding(
            get: { mode == .local },
            set: { mode = $0 ? .local : .combined }
        )
    }

    var body: some View {
        Toggle(isOn: isLocal) {
            Text("Only uncommitted")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(mode == .local
              ? "Showing uncommitted (staged + unstaged) changes"
              : "Showing all changes vs base branch (committed + uncommitted)")
    }
}
#endif
