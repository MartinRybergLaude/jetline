#if os(macOS)
import SwiftUI

/// Settings → Remote: the machines whose workspaces show up in the
/// sidebar next to this Mac's. Each runs its own `jetlined`, reached over
/// ssh; they're all connected at once.
struct EngineSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var setup: RemoteSetupRequest?

    var body: some View {
        Form {
            Section {
                ForEach(state.hosts.filter { !$0.isLocal }) { host in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.name).font(.body.weight(.medium))
                            EngineStatusLabel(connection: host.connection)
                        }
                        Spacer()
                        if case .reconnecting = host.connection.status {
                            Button("Retry") { host.connection.reconnectNow() }
                        } else if case .failed = host.connection.status {
                            Button("Retry") { host.connection.reconnectNow() }
                        }
                        Button("Set Up…") { setup = RemoteSetupRequest(hostId: host.id) }
                    }
                    .padding(.vertical, 2)
                }
                .onMove { state.moveRemoteHosts(from: $0, to: $1) }
                Button("Connect a Machine…") { setup = RemoteSetupRequest(hostId: nil) }
            } header: {
                Text("Remote machines")
            } footer: {
                Text("Each machine runs Jetline's engine (`jetlined`): its git worktrees, agents, terminals and run scripts live there, and its repositories get their own group in the sidebar. Closing the laptop leaves everything running. Connecting a machine checks it over ssh and installs or updates the engine for you; the machine needs `git`, and `gh` and the agent CLIs you use, logged in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $setup) { request in
            ConnectRemoteSheet(request: request) { setup = nil }
        }
    }
}

/// "Connected to devbox (Linux · jetlined 0.8.0)" and friends.
struct EngineStatusLabel: View {
    let connection: EngineConnection

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var color: Color {
        switch connection.status {
        case .connected: return .green
        case .connecting, .reconnecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var title: String {
        let name = connection.target.displayName
        switch connection.status {
        case .idle: return "Not connected"
        case .connecting: return "Connecting to \(name)…"
        case .connected: return connection.isLocal ? "Running on this Mac" : "Connected to \(name)"
        case let .reconnecting(attempt, _): return "Reconnecting to \(name)… (attempt \(attempt))"
        case .failed: return "Couldn't connect to \(name)"
        }
    }

    private var detail: String? {
        switch connection.status {
        case .connected:
            guard let hello = connection.hello, !connection.isLocal else { return nil }
            return "\(hello.hostName) · \(hello.platform) · engine \(hello.engineVersion)"
        case let .reconnecting(_, error): return error
        case let .failed(message): return message
        default: return nil
        }
    }
}
#endif
