#if os(macOS)
import SwiftUI

struct RepositorySection: View {
    @EnvironmentObject private var state: AppState
    /// Observed so the row repaints when a deferred icon scan lands.
    /// Singleton: the loader's lifecycle is the app's, not this view's.
    @ObservedObject private var iconLoader = RepoIconLoader.shared
    let repo: Repository
    /// Opens the creation sheet; a workspace id stacks the new one on it.
    let onNewWorkspace: (_ baseWorkspaceId: String?) -> Void
    let onOpenSettings: () -> Void
    /// A machine's title, when this is the first repository under it. It
    /// rides in this section's header because a row of its own would sit a
    /// full section gap above its repositories.
    var groupHeader: AnyView? = nil

    @State private var expanded: Bool = true
    @State private var hovering = false
    @State private var rowHeight: CGFloat = 30
    @GestureState private var rowDrag: RowDrag?

    /// Live state of a hold-then-drag row reorder. `@GestureState` so an
    /// interrupted drag can never leave a row stuck in the lifted look.
    private struct RowDrag: Equatable {
        let workspaceId: String
        let fromIndex: Int
        var translation: CGFloat = 0
    }

    private var workspaces: [Workspace] { state.workspacesByRepo[repo.id] ?? [] }
    /// Rows as shown: each stack's layers under the workspace they sit on.
    private var rows: [(workspace: Workspace, depth: Int)] {
        WorkspaceStacks.sidebarOrder(workspaces, repo: repo)
    }
    private var hasWorkspaces: Bool { !workspaces.isEmpty }
    private var baseWorkspaceId: String { state.repositoryBaseWorkspaceId(for: repo) }
    private var isBaseSelected: Bool {
        state.selectedWorkspaceId == baseWorkspaceId
    }
    private var isBaseOpen: Bool {
        state.workspaceState(for: baseWorkspaceId).hasAgentTabs
    }

    var body: some View {
        Section {
            if expanded {
                // Rows are plain views with a tap gesture, not Buttons — a
                // Button would capture mouseDown and starve the hold+drag
                // reorder gesture (same pitfall as the header, see below).
                let rows = self.rows
                let dropGap = dropGap(in: rows)
                ForEach(Array(rows.enumerated()), id: \.element.workspace.id) { idx, row in
                    let ws = row.workspace
                    WorkspaceRow(workspace: ws, depth: row.depth) { onNewWorkspace(ws.id) }
                        .opacity(rowDrag?.workspaceId == ws.id ? 0.55 : 1)
                        .background {
                            if rowDrag?.workspaceId == ws.id {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            }
                        }
                        .overlay(alignment: .top) {
                            if dropGap == idx {
                                dropIndicator.offset(y: -1)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if idx == rows.count - 1, dropGap == rows.count {
                                dropIndicator.offset(y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.selectWorkspace(ws.id) }
                        // Stacks move as a whole, by their bottom layer.
                        .gesture(reorderGesture(for: ws, at: idx, in: rows), isEnabled: row.depth == 0)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            rowHeight = $0
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: -8, bottom: 1, trailing: -8))
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                if let groupHeader {
                    groupHeader.hostHeaderPlacement()
                }
                repositoryHeader
            }
        }
    }

    private var repositoryHeader: some View {
        HStack(spacing: 0) {
            // Only the chevron toggles, and the icon + name area stays a
            // plain Button with no drag-capturing wrapper around the whole
            // row, so `.onMove` can still arm on it; the trailing controls
            // stay narrow for the same reason.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                // Small and near-black, as Music draws its disclosure arrows.
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .opacity(hasWorkspaces ? 1 : 0)
                    .frame(width: SidebarMetrics.disclosureColumn)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!hasWorkspaces)
            .help(expanded ? "Hide workspaces" : "Show workspaces")
            .padding(.leading, SidebarMetrics.leading)
            Button {
                state.selectRepositoryHead(repo)
            } label: {
                HStack(spacing: SidebarMetrics.labelGap) {
                    Group {
                        if state.isLocal(repoId: repo.id), let favicon = iconLoader.icon(for: repo.path) {
                            Image(nsImage: favicon)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "folder")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(.primary)
                        }
                    }
                    .frame(width: SidebarMetrics.iconColumn, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(repo.name)
                            .font(.body)
                            .textCase(nil)
                            .foregroundStyle(isBaseSelected ? Color.accentColor.opacity(0.9) : Color.primary)
                            .lineLimit(1)
                        Text(repo.defaultBranch)
                            .font(.caption2)
                            .textCase(nil)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, SidebarMetrics.iconLeading - SidebarMetrics.leading - SidebarMetrics.disclosureColumn)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(repo.defaultBranch) in \(repo.name)")
            // Controls fade in on hover, as in the machine header above.
            HStack(spacing: 10) {
                Button { onNewWorkspace(nil) } label: {
                    Image(systemName: "plus")
                }
                .help("New workspace")
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .help("Repository settings")
            }
            .font(.system(size: 13, weight: .regular))
            .opacity(hovering ? 1 : 0)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .background {
            if isBaseSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        // The sidebar list ignores `.listRowInsets` on section headers and
        // places the header slot 6pt to the right of row slots (same
        // width), so a plain translation is what lines the header pill up
        // with the workspace-row pills below.
        .offset(x: -6)
        // Compactness comes from the real paddings above, not from
        // negative padding: the list sizes the header slot from the
        // content's fitting height and clips exactly at the slot's top,
        // so a negative top padding shears that many points off the
        // selection pill (`listSectionSpacing` et al., which would trim
        // the spacing properly, are macOS-unavailable).
        .contextMenu {
            Button("New workspace…") { onNewWorkspace(nil) }
            if isBaseOpen {
                Button("Close workspace") { state.closeWorkspace(baseWorkspaceId) }
            }
            Divider()
            Button("Repository settings…", action: onOpenSettings)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path)])
            }
            Divider()
            Button("Remove…", role: .destructive) {
                state.removeRepository(repo.id)
            }
        }
    }

    /// Hold-to-lift, drag-to-reorder. List `.onMove` can't be used here
    /// (rows need a full-surface click-to-select, which captures the
    /// mouseDown `.onMove` arms from), so this is the sidebar analog of the
    /// tab strip's custom reorder gesture: the long press lifts the row,
    /// the drag moves an insertion indicator, release commits. Nothing
    /// mutates mid-drag, so the gesture — and the constraint that a row
    /// only reorders inside its own repository — survives the whole
    /// interaction.
    private func reorderGesture(for ws: Workspace, at index: Int, in rows: [(workspace: Workspace, depth: Int)]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 6)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($rowDrag) { value, drag, _ in
                guard case .second(true, let dragValue) = value else { return }
                if drag == nil {
                    drag = RowDrag(workspaceId: ws.id, fromIndex: index)
                }
                drag?.translation = dragValue?.translation.height ?? 0
            }
            .onEnded { value in
                guard case .second(true, .some(let dragValue)) = value else { return }
                // Re-resolve the row by id — the array may have shifted
                // under the drag (poll-driven delete, new workspace).
                guard let from = rows.firstIndex(where: { $0.workspace.id == ws.id }) else { return }
                let dest = dropDestination(from: from, translation: dragValue.translation.height, in: rows)
                guard dest != from, dest != from + 1 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.moveWorkspaceStack(in: repo.id, moving: ws.id, toGap: dest)
                }
            }
    }

    /// Insertion gap the lifted row would land in, in `onMove`'s
    /// "insert before this index" convention. Derived from the vertical
    /// translation and the uniform row pitch (row height plus the 1pt
    /// `listRowInsets` above and below), clamped to this repo's rows, then
    /// snapped out of any stack it would split: stacks only move whole.
    private func dropDestination(from index: Int, translation: CGFloat, in rows: [(workspace: Workspace, depth: Int)]) -> Int {
        let pitch = max(rowHeight + 2, 1)
        let shift = Int((translation / pitch).rounded())
        let landing = max(0, min(rows.count - 1, index + shift))
        var gap = landing > index ? landing + 1 : landing
        while gap < rows.count, rows[gap].depth > 0 { gap += 1 }
        // The moved stack's own end is a no-op spot, same as its start.
        let end = rows[(index + 1)...].firstIndex { $0.depth == 0 } ?? rows.count
        return gap == end ? index : gap
    }

    /// Gap to draw the indicator in, `nil` while the drop would be a no-op.
    private func dropGap(in rows: [(workspace: Workspace, depth: Int)]) -> Int? {
        guard let drag = rowDrag else { return nil }
        let dest = dropDestination(from: drag.fromIndex, translation: drag.translation, in: rows)
        guard dest != drag.fromIndex, dest != drag.fromIndex + 1 else { return nil }
        return dest
    }

    private var dropIndicator: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(height: 2)
            .padding(.horizontal, 6)
    }
}
#endif
