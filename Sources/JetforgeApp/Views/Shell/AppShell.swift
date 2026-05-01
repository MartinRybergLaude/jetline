import SwiftUI

/// Top-level layout: sidebar on the left, terminal in the middle,
/// inspector on the right (toggleable).
struct AppShell: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            MainArea()
                .inspector(isPresented: inspectorBinding) {
                    InspectorView()
                        .inspectorColumnWidth(min: 240, ideal: 320, max: 480)
                }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.inspectorVisible.toggle()
                } label: {
                    Image(systemName: state.inspectorVisible
                          ? "sidebar.right"
                          : "sidebar.right")
                        .symbolVariant(state.inspectorVisible ? .fill : .none)
                }
                .help("Toggle inspector")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    /// Inspector hides when nothing is selected (mirrors the previous logic),
    /// otherwise tracks the user-toggled visibility flag.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { state.inspectorVisible && state.selectedWorkspaceId != nil },
            set: { state.inspectorVisible = $0 }
        )
    }
}

private struct MainArea: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let id = state.selectedWorkspaceId, let ws = state.workspaceById(id) {
            TerminalArea(workspace: ws)
        } else {
            WelcomeView()
        }
    }
}
