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

    private var workspaces: [Workspace] { state.workspacesByRepo[repo.id] ?? [] }
    private var hasWorkspaces: Bool { !workspaces.isEmpty }
    private var isBaseSelected: Bool {
        state.selectedWorkspaceId == state.repositoryBaseWorkspaceId(for: repo)
    }

    var body: some View {
        Section {
            if expanded {
                ForEach(workspaces) { ws in
                    Button {
                        state.selectWorkspace(ws.id)
                    } label: {
                        WorkspaceRow(workspace: ws)
                    }
                    .buttonStyle(.plain)
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
                    .background {
                        if isBaseSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(repo.defaultBranch) in \(repo.name)")
                Spacer(minLength: 0)
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
            .padding(.vertical, 4)
            .contextMenu {
                Button("New workspace…", action: onNewWorkspace)
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
}
