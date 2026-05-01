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
                    WorkspaceRow(workspace: ws)
                        .tag(ws.id)
                }

                Button(action: onNewWorkspace) {
                    Label("New workspace", systemImage: "plus.rectangle")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        } header: {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text(repo.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(nil)
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Repository settings")
            }
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
