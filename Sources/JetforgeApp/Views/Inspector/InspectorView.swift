import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                ChangesPanel()
                    .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Changes").font(.headline)
            Spacer()
            Button {
                if let id = state.selectedWorkspaceId, let ws = state.workspaceById(id) {
                    Task { await state.refreshDiff(for: ws) }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
