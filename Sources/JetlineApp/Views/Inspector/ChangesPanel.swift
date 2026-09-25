import SwiftUI

struct ChangesPanel: View {
    @EnvironmentObject private var state: AppState
    let mode: DiffMode

    var body: some View {
        if let id = state.inspectorWorkspaceId,
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
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    let workspaceState: WorkspaceState
    let mode: DiffMode
    @Environment(InspectorUIState.self) private var ui

    /// Full paths of folders the user has collapsed in the file tree.
    private var collapsedFolders: Set<String> {
        get { ui.collapsedFolders[workspace.id] ?? [] }
        nonmutating set { ui.collapsedFolders[workspace.id] = newValue }
    }

    /// Horizontal inset per tree level.
    static let indentWidth: CGFloat = 12
    /// Width reserved for a folder's disclosure chevron, so file names line
    /// up with folder names at the same depth.
    static let chevronWidth: CGFloat = 10

    var body: some View {
        let snap = snapshot
        if snap.isEmpty {
            InspectorPlaceholder(
                systemImage: "checkmark.circle",
                title: emptyTitle
            )
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                summaryHeader(snap: snap)
                ForEach(DiffTree.rows(for: snap.files, collapsed: collapsedFolders)) { row in
                    Group {
                        switch row {
                        case .folder(let path, let name, _): folderRow(path: path, name: name)
                        case .file(let file, _):             fileRow(file)
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * Self.indentWidth)
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

    private func folderRow(path: String, name: String) -> some View {
        let collapsed = collapsedFolders.contains(path)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed { collapsedFolders.remove(path) } else { collapsedFolders.insert(path) }
            }
        } label: {
            treeRowLabel(name: name) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.chevronWidth)
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
            } trailing: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .help(path)
    }

    /// Opens the file's full diff as a tab in the main area.
    private func fileRow(_ file: FileDiff) -> some View {
        let isOpen = workspaceState.activeTab == .diff(file.id)
        return Button {
            state.openDiffTab(path: file.path, mode: mode, in: workspace.id)
        } label: {
            treeRowLabel(name: (file.path as NSString).lastPathComponent) {
                Color.clear.frame(width: Self.chevronWidth, height: 1)
                FileStatusBadge(status: file.status)
            } trailing: {
                Text("+\(file.additions)").foregroundStyle(Color.readableGreen)
                Text("-\(file.deletions)").foregroundStyle(.red)
            }
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isOpen ? Color.accentColor.opacity(0.15) : .clear)
                .padding(.horizontal, -4)
        )
        .help(file.path)
    }

    private func treeRowLabel(
        name: String,
        @ViewBuilder leading: () -> some View,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            trailing()
        }
        .monoFont(.caption)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func summaryHeader(snap: DiffSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("\(snap.files.count) file\(snap.files.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("+\(snap.totalAdditions)")
                .foregroundStyle(Color.readableGreen)
            Text("−\(snap.totalDeletions)")
                .foregroundStyle(.red)
        }
        .monoFont(.caption)
    }
}
