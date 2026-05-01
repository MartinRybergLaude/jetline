import SwiftUI
import AppKit

struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    private var isSelected: Bool {
        state.selectedWorkspaceId == workspace.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(workspace.name)
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor.opacity(0.9) : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let stats = state.diffByWorkspace[workspace.id], !stats.files.isEmpty {
                ChangesPill(adds: stats.totalAdditions, dels: stats.totalDeletions)
            }
        }
        .padding(.leading, 52)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
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
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .opacity(0.85)
    }
}
