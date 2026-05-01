import SwiftUI

struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: workspace.agent == .claude ? "sparkles" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(workspace.name).lineLimit(1)
                Text(workspace.branchName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let stats = state.diffByWorkspace[workspace.id], !stats.files.isEmpty {
                ChangesPill(adds: stats.totalAdditions, dels: stats.totalDeletions)
            }
        }
        .contextMenu {
            Button("Reveal worktree in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.worktreePath)])
            }
            Divider()
            Button("Archive (keep worktree)") {
                Task { await state.archiveWorkspace(workspace, removeWorktree: false) }
            }
            Button("Delete worktree…", role: .destructive) {
                Task { await state.archiveWorkspace(workspace, removeWorktree: true) }
            }
        }
    }
}

private struct ChangesPill: View {
    let adds: Int
    let dels: Int

    var body: some View {
        HStack(spacing: 4) {
            if adds > 0 {
                Text("+\(adds)").foregroundStyle(.green)
            }
            if dels > 0 {
                Text("-\(dels)").foregroundStyle(.red)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .opacity(0.85)
    }
}
