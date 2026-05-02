import SwiftUI
import AppKit

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
        .background(WindowTabbingDisabler())
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

/// Disables NSWindow tabbing for the hosting window — removes the
/// View → Show Tab Bar / Merge All Windows / Move Tab to New Window items.
private struct WindowTabbingDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.tabbingMode = .disallowed }
        return v
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.window?.tabbingMode = .disallowed
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
