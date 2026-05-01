import SwiftUI

struct ChangesPanel: View {
    @EnvironmentObject private var state: AppState

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
        let snap = state.diffByWorkspace[workspace.id] ?? .empty
        if snap.files.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No changes vs \(workspace.baseBranch)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                summaryHeader(snap: snap, baseBranch: workspace.baseBranch)
                ForEach(snap.files) { file in
                    FileDiffSection(file: file)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func summaryHeader(snap: DiffSnapshot, baseBranch: String) -> some View {
        HStack(spacing: 6) {
            Text("\(snap.files.count) file\(snap.files.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(snap.totalAdditions)")
                .foregroundStyle(.green)
            Text("-\(snap.totalDeletions)")
                .foregroundStyle(.red)
        }
        .font(.system(.caption, design: .monospaced))
    }
}
