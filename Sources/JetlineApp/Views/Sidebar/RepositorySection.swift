import SwiftUI

struct RepositorySection: View {
    @EnvironmentObject private var state: AppState
    /// Observed so the row repaints when a deferred icon scan lands.
    /// Singleton: the loader's lifecycle is the app's, not this view's.
    @ObservedObject private var iconLoader = RepoIconLoader.shared
    let repo: Repository
    let onNewWorkspace: () -> Void
    let onOpenSettings: () -> Void

    @State private var expanded: Bool = true
    @State private var headerHovering = false
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
    private var hasWorkspaces: Bool { !workspaces.isEmpty }
    private var baseWorkspaceId: String { state.repositoryBaseWorkspaceId(for: repo) }
    private var isBaseSelected: Bool {
        state.selectedWorkspaceId == baseWorkspaceId
    }
    private var isBaseOpen: Bool {
        !state.workspaceState(for: baseWorkspaceId).sessions.isEmpty
    }

    var body: some View {
        Section {
            if expanded {
                // Rows are plain views with a tap gesture, not Buttons — a
                // Button would capture mouseDown and starve the hold+drag
                // reorder gesture (same pitfall as the header, see below).
                ForEach(Array(workspaces.enumerated()), id: \.element.id) { idx, ws in
                    WorkspaceRow(workspace: ws)
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
                            if idx == workspaces.count - 1, dropGap == workspaces.count {
                                dropIndicator.offset(y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.selectWorkspace(ws.id) }
                        .gesture(reorderGesture(for: ws, at: idx))
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            rowHeight = $0
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 1, leading: -8, bottom: 1, trailing: -8))
                        .listRowSeparator(.hidden)
                }
            }
        } header: {
            HStack(spacing: 8) {
                // Small dedicated chevron button. The expand/collapse used
                // to be a Button (or tap gesture) wrapping the entire row,
                // which captured mouseDown and prevented `.onMove` from
                // arming the row drag. Keeping the tap target tiny — just
                // the chevron — means the icon + name area is plain
                // non-interactive content, which `.onMove` is free to
                // drag. The plus/gear buttons at the trailing edge are
                // also Buttons but stay narrow for the same reason.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Group {
                        if hasWorkspaces {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 12, alignment: .center)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasWorkspaces)
                Button {
                    state.selectRepositoryHead(repo)
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            if let favicon = iconLoader.icon(for: repo.path) {
                                Image(nsImage: favicon)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 15, height: 15)
                            } else {
                                Image(systemName: "folder")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .frame(width: 22, alignment: .center)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(repo.name)
                                .font(.body)
                                .textCase(nil)
                                .foregroundStyle(isBaseSelected ? Color.accentColor.opacity(0.9) : Color.primary)
                            Text(repo.defaultBranch)
                                .font(.caption2)
                                .textCase(nil)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(repo.defaultBranch) in \(repo.name)")
                Spacer(minLength: 0)
                if isBaseOpen {
                    CloseWorkspaceButton(visible: headerHovering) {
                        state.closeWorkspace(baseWorkspaceId)
                    }
                }
                Button(action: onNewWorkspace) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New workspace")
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Repository settings")
                .padding(.trailing, 8)
            }
            .padding(.leading, 8)
            .padding(.vertical, 4)
            .background {
                if isBaseSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .overlay(alignment: .leading) {
                OpenWorkspaceBar(isOpen: isBaseOpen, isSelected: isBaseSelected, height: 26)
            }
            // The sidebar list ignores `.listRowInsets` on section headers and
            // places the header slot 6pt to the right of row slots (same
            // width), so a plain translation is what lines the header pill up
            // with the workspace-row pills below.
            .offset(x: -6)
            .onHover { headerHovering = $0 }
            .contextMenu {
                Button("New workspace…", action: onNewWorkspace)
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
    }

    /// Hold-to-lift, drag-to-reorder. List `.onMove` can't be used here
    /// (rows need a full-surface click-to-select, which captures the
    /// mouseDown `.onMove` arms from), so this is the sidebar analog of the
    /// tab strip's custom reorder gesture: the long press lifts the row,
    /// the drag moves an insertion indicator, release commits. Nothing
    /// mutates mid-drag, so the gesture — and the constraint that a row
    /// only reorders inside its own repository — survives the whole
    /// interaction.
    private func reorderGesture(for ws: Workspace, at index: Int) -> some Gesture {
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
                // under the drag (poll-driven archive, new workspace).
                guard let from = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
                let dest = dropDestination(from: from, translation: dragValue.translation.height)
                guard dest != from, dest != from + 1 else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.moveWorkspaces(in: repo.id, from: IndexSet(integer: from), to: dest)
                }
            }
    }

    /// Insertion gap the lifted row would land in, in `onMove`'s
    /// "insert before this index" convention. Derived from the vertical
    /// translation and the uniform row pitch (row height plus the 1pt
    /// `listRowInsets` above and below), clamped to this repo's rows.
    private func dropDestination(from index: Int, translation: CGFloat) -> Int {
        let pitch = max(rowHeight + 2, 1)
        let shift = Int((translation / pitch).rounded())
        let landing = max(0, min(workspaces.count - 1, index + shift))
        return landing > index ? landing + 1 : landing
    }

    /// Gap to draw the indicator in, `nil` while the drop would be a no-op.
    private var dropGap: Int? {
        guard let drag = rowDrag else { return nil }
        let dest = dropDestination(from: drag.fromIndex, translation: drag.translation)
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
