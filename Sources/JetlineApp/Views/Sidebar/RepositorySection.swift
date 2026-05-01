import SwiftUI

struct RepositorySection: View {
    @EnvironmentObject private var state: AppState
    let repo: Repository
    let onNewWorkspace: () -> Void
    let onOpenSettings: () -> Void

    @State private var expanded: Bool = true

    var body: some View {
        Section {
            if expanded {
                ForEach(state.workspacesByRepo[repo.id] ?? []) { ws in
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
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, alignment: .center)
                        Group {
                            if let favicon = RepoIconLoader.icon(for: repo.path) {
                                Image(nsImage: favicon)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "folder")
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundStyle(.primary)
                            }
                        }
                        .frame(width: 22, alignment: .center)
                        Text(repo.name)
                            .font(.body)
                            .textCase(nil)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
