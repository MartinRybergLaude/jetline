import SwiftUI

struct ChangesPanel: View {
    @EnvironmentObject private var state: AppState
    let mode: DiffMode

    var body: some View {
        if let id = state.selectedWorkspaceId,
           let ws = state.workspaceById(id) {
            ChangesPanelContent(
                workspace: ws,
                workspaceState: state.workspaceState(for: ws.id),
                mode: mode
            )
        } else {
            EmptyView()
        }
    }
}

private struct ChangesPanelContent: View {
    let workspace: Workspace
    let workspaceState: WorkspaceState
    let mode: DiffMode

    var body: some View {
        let snap = snapshot
        if snap.isEmpty {
            InspectorPlaceholder(
                systemImage: "checkmark.circle",
                title: emptyTitle
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                summaryHeader(snap: snap)
                ForEach(snap.files) { file in
                    FileDiffSection(file: file)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var snapshot: DiffSnapshot {
        switch mode {
        case .local:    return workspaceState.localDiff ?? .empty
        case .combined: return workspaceState.diff ?? .empty
        }
    }

    private var emptyTitle: String {
        switch mode {
        case .combined: return "No changes vs \(workspace.baseBranch)"
        case .local:    return "No uncommitted changes"
        }
    }

    private func summaryHeader(snap: DiffSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("\(snap.files.count) file\(snap.files.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(snap.totalAdditions)")
                .foregroundStyle(.green)
            Text("−\(snap.totalDeletions)")
                .foregroundStyle(.red)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
