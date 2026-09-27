#if os(macOS)
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
            .onMove { offsets, destination in
                state.moveRepositorySections(from: offsets, to: destination)
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

    /// Floats over the list rather than sitting in a bar: the button carries
    /// its own glass, so the sidebar material reads straight through to the
    /// window edge. `safeAreaInset` still reserves the height, so the last
    /// row scrolls clear of it.
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            EngineStatusPill(connection: state.connection)
            if let message = state.prTrackerStatus.userMessage {
                PRTrackerStatusPill(message: message)
            }
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
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 10)
            // Level with the chat composer's pill row across the window.
            .padding(.bottom, 12)
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
#endif
