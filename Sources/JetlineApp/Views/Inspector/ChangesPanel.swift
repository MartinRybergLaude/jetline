import SwiftUI

struct ChangesPanel: View {
    @EnvironmentObject private var state: AppState
    let mode: DiffMode

    var body: some View {
        if let id = state.selectedWorkspaceId,
           let ws = state.workspaceById(id) {
            content(for: ws)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(for workspace: Workspace) -> some View {
        let snap = snapshot(for: workspace.id)
        if snap.isEmpty {
            InspectorPlaceholder(
                systemImage: "checkmark.circle",
                title: emptyTitle(for: workspace)
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

    private func snapshot(for workspaceId: String) -> DiffSnapshot {
        switch mode {
        case .pr:       return state.prDiffByWorkspace[workspaceId] ?? .empty
        case .local:    return state.localDiffByWorkspace[workspaceId] ?? .empty
        case .combined: return state.diffByWorkspace[workspaceId] ?? .empty
        }
    }

    private func emptyTitle(for workspace: Workspace) -> String {
        switch mode {
        case .pr, .combined: return "No changes vs \(workspace.baseBranch)"
        case .local:         return "No uncommitted changes"
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
