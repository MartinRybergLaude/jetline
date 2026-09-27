#if os(macOS)
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCreation: Repository?
    @State private var showingRepoSettings: Repository?

    var body: some View {
        List {
            ForEach(state.hosts) { host in
                // With only this Mac there's nothing to group.
                if state.hosts.count > 1 {
                    HostGroupHeader(host: host, isFirst: host === state.hosts.first) {
                        addRepository(on: host)
                    }
                }
                ForEach(host.repositories) { repo in
                    RepositorySection(
                        repo: repo,
                        onNewWorkspace: { showingCreation = repo },
                        onOpenSettings: { showingRepoSettings = repo }
                    )
                    // A remote whose link is down stays listed, dimmed.
                    .opacity(host.isLocal || host.isSynced ? 1 : 0.5)
                }
                .onMove { offsets, destination in
                    state.moveRepositorySections(in: host, from: offsets, to: destination)
                }

                if host.repositories.isEmpty, host.isSynced || host.isLocal {
                    emptyHint(for: host)
                }
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
        .sheet(item: $state.pendingRemoteSetup) { request in
            ConnectRemoteSheet(request: request) { state.pendingRemoteSetup = nil }
        }
    }

    private func addRepository(on host: EngineHost) {
        Task {
            if let repo = await state.addRepository(on: host) {
                // Drop the user straight into settings for the freshly-added
                // repo so they can configure setup / run scripts before
                // spawning a workspace.
                showingRepoSettings = repo
            }
        }
    }

    private func emptyHint(for host: EngineHost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.hosts.count > 1 ? "No repositories here yet" : "No repositories yet")
                .font(.headline)
            Text(host.isLocal
                 ? "Add a local git repo and start a workspace."
                 : "Add a git repo on \(host.name) and start a workspace.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, state.hosts.count > 1 ? 6 : 16)
        .listRowSeparator(.hidden)
    }

    /// Floats over the list rather than sitting in a bar: the button carries
    /// its own glass, so the sidebar material reads straight through to the
    /// window edge. `safeAreaInset` still reserves the height, so the last
    /// row scrolls clear of it.
    private var sidebarFooter: some View {
        VStack(spacing: 8) {
            if state.hosts.count == 1, let message = state.prTrackerStatus.userMessage {
                PRTrackerStatusPill(message: message)
            }
            Menu {
                ForEach(state.hosts) { host in
                    Button(host.isLocal ? "On This Mac…" : "On \(host.name)…") { addRepository(on: host) }
                        .disabled(!host.isLocal && !host.isSynced)
                }
                Divider()
                Button("Connect a Machine…") { state.pendingRemoteSetup = RemoteSetupRequest(hostId: nil) }
            } label: {
                Label("Add repository", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            } primaryAction: {
                addRepository(on: state.localHost)
            }
            .menuIndicator(.visible)
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .padding(.horizontal, 10)
            // Level with the chat composer's pill row across the window.
            .padding(.bottom, 12)
        }
    }
}

/// The divider and title above one machine's repositories: its name, the
/// link's state, and what you can do with it.
private struct HostGroupHeader: View {
    @EnvironmentObject private var state: AppState
    let host: EngineHost
    let isFirst: Bool
    let onAddRepository: () -> Void
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isFirst {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: 1)
                    .padding(.bottom, 4)
            }
            HStack(spacing: 7) {
                Image(systemName: host.isLocal ? "laptopcomputer" : "server.rack")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(host.name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                    .help(statusHelp)
                Spacer(minLength: 4)
                Button(action: onAddRepository) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!host.isLocal && !host.isSynced)
                .help("Add a repository on \(host.isLocal ? "this Mac" : host.name)")
                if !host.isLocal {
                    Menu {
                        Button("Reconnect") { host.connection.reconnectNow() }
                        Button("Set Up / Update jetlined…") {
                            state.pendingRemoteSetup = RemoteSetupRequest(hostId: host.id)
                        }
                        Divider()
                        Button("Remove \(host.name)…", role: .destructive) { confirmingRemoval = true }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if needsSetup {
                // Most first-time failures are a missing or outdated engine.
                Button("Set Up…") { state.pendingRemoteSetup = RemoteSetupRequest(hostId: host.id) }
                    .controlSize(.small)
            }
        }
        .padding(.top, isFirst ? 2 : 8)
        .padding(.bottom, 2)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
        .confirmationDialog(
            "Remove \(host.name) from Jetline?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove", role: .destructive) { state.removeRemoteHost(host.id) }
        } message: {
            Text("Its workspaces disappear from the sidebar. Everything keeps running on \(host.name); add it again to get back to it.")
        }
    }

    private var statusColor: Color {
        switch host.connection.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var statusHelp: String {
        switch host.connection.status {
        case .connected:
            if let hello = host.connection.hello, !host.isLocal {
                return "Connected · \(hello.hostName) · \(hello.platform) · engine \(hello.engineVersion)"
            }
            return "Connected"
        case .connecting: return "Connecting…"
        case let .reconnecting(attempt, _): return "Reconnecting (attempt \(attempt))…"
        case let .failed(message): return message
        case .idle: return "Not connected"
        }
    }

    private var needsSetup: Bool {
        guard !host.isLocal else { return false }
        switch host.connection.status {
        case .failed, .reconnecting: return true
        default: return false
        }
    }

    /// Only when something needs saying: a down link, or gh trouble there.
    private var detail: String? {
        switch host.connection.status {
        case .connecting where !host.isLocal: return "Connecting…"
        case let .reconnecting(_, error): return error.map { "Reconnecting — \($0)" } ?? "Reconnecting…"
        case let .failed(message): return message
        default: return host.prTrackerStatus.userMessage
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
