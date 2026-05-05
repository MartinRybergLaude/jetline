import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCreation: Repository?
    @State private var showingRepoSettings: Repository?

    var body: some View {
        List {
            ForEach(state.repositories) { repo in
                RepositorySection(
                    repo: repo,
                    onNewWorkspace: { showingCreation = repo },
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
        .sheet(item: $showingCreation) { repo in
            WorkspaceCreationSheet(repository: repo)
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
            if let message = state.prTrackerStatus.userMessage {
                PRTrackerStatusPill(message: message)
                Divider()
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        if let repo = await state.addRepository() {
                            // Drop the user straight into settings for the
                            // freshly-added repo so they can configure setup
                            // / run scripts before spawning a workspace —
                            // the next workspace will then see those scripts
                            // on first creation.
                            showingRepoSettings = repo
                        }
                    }
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

/// Sidebar footer banner that surfaces persistent gh failures (missing CLI,
/// auth required) so PR icons not updating has a visible explanation rather
/// than just looking broken.
private struct PRTrackerStatusPill: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.08))
    }
}
