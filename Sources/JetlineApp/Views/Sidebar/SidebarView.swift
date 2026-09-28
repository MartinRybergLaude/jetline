#if os(macOS)
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingCreation: CreationRequest?
    @State private var showingRepoSettings: Repository?
    @State private var collapsedHosts: Set<String> = []

    var body: some View {
        List {
            ForEach(state.hosts) { host in
                // With only this Mac there's nothing to group.
                let grouped = state.hosts.count > 1
                let repos = isCollapsed(host) ? [] : host.repositories
                if grouped, repos.isEmpty {
                    hostHeader(host)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                }
                ForEach(repos) { repo in
                    RepositorySection(
                        repo: repo,
                        onNewWorkspace: { showingCreation = CreationRequest(repository: repo, baseWorkspaceId: $0) },
                        onOpenSettings: { showingRepoSettings = repo },
                        groupHeader: grouped && repo.id == repos.first?.id ? AnyView(hostHeader(host)) : nil
                    )
                    // A remote whose link is down stays listed, greyed out.
                    .saturation(host.isLocal || host.isSynced ? 1 : 0)
                    .opacity(host.isLocal || host.isSynced ? 1 : 0.5)
                }
                .onMove { offsets, destination in
                    state.moveRepositorySections(in: host, from: offsets, to: destination)
                }

                if !isCollapsed(host), host.repositories.isEmpty, host.isSynced || host.isLocal {
                    emptyHint(for: host)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
        .sheet(item: $showingCreation) { request in
            WorkspaceCreationSheet(repository: request.repository, baseWorkspaceId: request.baseWorkspaceId)
        }
        .sheet(item: $showingRepoSettings) { repo in
            RepositorySettingsSheet(repository: repo)
        }
        .sheet(item: $state.pendingRemoteSetup) { request in
            ConnectRemoteSheet(request: request) { state.pendingRemoteSetup = nil }
        }
    }

    private func hostHeader(_ host: EngineHost) -> HostGroupHeader {
        HostGroupHeader(host: host, isFirst: host === state.hosts.first, isExpanded: expansion(of: host)) {
            addRepository(on: host)
        }
    }

    private func isCollapsed(_ host: EngineHost) -> Bool {
        state.hosts.count > 1 && collapsedHosts.contains(host.id)
    }

    private func expansion(of host: EngineHost) -> Binding<Bool> {
        Binding(
            get: { !collapsedHosts.contains(host.id) },
            set: { expanded in
                if expanded { collapsedHosts.remove(host.id) } else { collapsedHosts.insert(host.id) }
            }
        )
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

/// The creation sheet to show: which repo, and the workspace to stack on.
private struct CreationRequest: Identifiable {
    let repository: Repository
    let baseWorkspaceId: String?

    var id: String { repository.id + "|" + (baseWorkspaceId ?? "") }
}

/// The title above one machine's repositories, drawn like a Finder sidebar
/// section header: plain secondary text, separated by whitespace, with its
/// controls fading in on hover. A remote's link shows as a light beside its
/// name: green when up, yellow while (re)connecting, red when it gave up.
private struct HostGroupHeader: View {
    @EnvironmentObject private var state: AppState
    let host: EngineHost
    let isFirst: Bool
    @Binding var isExpanded: Bool
    let onAddRepository: () -> Void
    @State private var hovering = false
    @State private var confirmingRemoval = false
    @State private var forwardingPort = false
    @State private var portText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(host.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                statusIndicator
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    Button(action: onAddRepository) {
                        Image(systemName: "plus")
                    }
                    .disabled(!host.isLocal && !host.isSynced)
                    .help("Add a repository on \(host.isLocal ? "this Mac" : host.name)")
                    if !host.isLocal {
                        Menu {
                            menuItems
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("\(host.name) options")
                    }
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                    }
                    .help(isExpanded ? "Hide" : "Show")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
            }
            .frame(minHeight: 18)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .contextMenu {
                Button(host.isLocal ? "Add Repository…" : "Add Repository on \(host.name)…", action: onAddRepository)
                    .disabled(!host.isLocal && !host.isSynced)
                if !host.isLocal {
                    Divider()
                    menuItems
                }
            }

            if let detail {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    if needsSetup {
                        // Most first-time failures are a missing or outdated engine.
                        Button("Set Up…") { state.pendingRemoteSetup = RemoteSetupRequest(hostId: host.id) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
            }
            if isExpanded, let ports = host.ports {
                ForwardedPortsView(ports: ports) {
                    state.pendingRemoteSetup = RemoteSetupRequest(hostId: host.id)
                }
            }
        }
        .padding(.top, isFirst ? 0 : 10)
        .confirmationDialog(
            "Remove \(host.name) from Jetline?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove", role: .destructive) { state.removeRemoteHost(host.id) }
        } message: {
            Text("Its workspaces disappear from the sidebar. Everything keeps running on \(host.name); add it again to get back to it.")
        }
        .alert("Forward a Port from \(host.name)", isPresented: $forwardingPort) {
            TextField("Port", text: $portText)
            Button("Forward") {
                if let port = Int(portText.trimmingCharacters(in: .whitespaces)) { host.ports?.forward(port) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will answer at localhost on this Mac, on the same port.")
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Reconnect") { host.connection.reconnectNow() }
        Button("Set Up / Update jetlined…") {
            state.pendingRemoteSetup = RemoteSetupRequest(hostId: host.id)
        }
        if let ports = host.ports {
            Divider()
            PortForwardingMenuItems(ports: ports) {
                portText = ""
                forwardingPort = true
            }
        }
        Divider()
        Button("Remove \(host.name)…", role: .destructive) { confirmingRemoval = true }
    }

    /// A status light, as in the Network settings pane.
    @ViewBuilder
    private var statusIndicator: some View {
        if !host.isLocal {
            Circle()
                .fill(statusColor.gradient)
                .frame(width: 6, height: 6)
                .help(statusHelp)
        }
    }

    private var statusColor: Color {
        switch host.connection.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
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

    /// A link down for this many tries is more than a blip: say why.
    private static let persistentDropAttempts = 3

    private var needsSetup: Bool {
        guard !host.isLocal else { return false }
        switch host.connection.status {
        case .failed: return true
        case let .reconnecting(attempt, _): return attempt >= Self.persistentDropAttempts
        default: return false
        }
    }

    /// Only when something needs saying: a link that stays down, or gh
    /// trouble there. A brief drop shows only in the light and the dimmed
    /// group.
    private var detail: String? {
        switch host.connection.status {
        case .connecting where !host.isLocal: return nil
        case let .reconnecting(attempt, error):
            guard attempt >= Self.persistentDropAttempts else { return nil }
            return error.map { "Reconnecting — \($0)" } ?? "Reconnecting…"
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
