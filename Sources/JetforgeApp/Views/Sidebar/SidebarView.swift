import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingNewWorkspace: Repository?
    @State private var showingRepoSettings: Repository?

    var body: some View {
        List(selection: Binding(
            get: { state.selectedWorkspaceId },
            set: { if let id = $0 { state.selectWorkspace(id) } }
        )) {
            ForEach(state.repositories) { repo in
                RepositorySection(
                    repo: repo,
                    onNewWorkspace: { showingNewWorkspace = repo },
                    onOpenSettings: { showingRepoSettings = repo }
                )
            }

            if state.repositories.isEmpty {
                emptyHint
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
        .sheet(item: $showingNewWorkspace) { repo in
            NewWorkspaceSheet(repository: repo)
        }
        .sheet(item: $showingRepoSettings) { repo in
            RepositorySettingsSheet(repository: repo)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No repositories yet")
                .font(.headline)
            Text("Add a local git repo and start a workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    Task { await state.addRepository() }
                } label: {
                    Label("Add repository", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
