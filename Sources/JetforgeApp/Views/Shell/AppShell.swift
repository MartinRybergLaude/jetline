import SwiftUI

/// Top-level layout: sidebar on the left, terminal in the middle,
/// inspector on the right (toggleable).
struct AppShell: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            HStack(spacing: 0) {
                MainArea()
                    .frame(minWidth: 360)
                if state.inspectorVisible, state.selectedWorkspaceId != nil {
                    Divider()
                    InspectorView()
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 480)
                }
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
