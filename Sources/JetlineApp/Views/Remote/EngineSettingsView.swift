#if os(macOS)
import SwiftUI

/// Settings → Remote: the machines whose workspaces show up in the
/// sidebar next to this Mac's. Each runs its own `jetlined`, reached over
/// ssh; they're all connected at once.
struct EngineSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var editing: RemoteEditor.Draft?

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
                        Button("Edit…") {
                            if case let .remote(remote) = host.connection.target {
                                editing = RemoteEditor.Draft(id: host.id, remote: remote)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .onMove { state.moveRemoteHosts(from: $0, to: $1) }
                Button("Add Remote Machine…") { editing = RemoteEditor.Draft(id: nil, remote: nil) }
            } header: {
                Text("Remote machines")
            } footer: {
                Text("Each machine runs Jetline's engine (`jetlined`): its git worktrees, agents, terminals and run scripts live there, and its repositories get their own group in the sidebar. Closing the laptop leaves everything running. Install the engine on a host with `make deploy-daemon HOST=<host>` from a Jetline checkout; the host needs `git`, `gh` and the agent CLIs, logged in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            RemoteEditor(draft: draft) { result in
                switch result {
                case let .save(id, remote):
                    if let id { state.updateRemoteHost(id, remote: remote) } else { state.addRemoteHost(remote) }
                case let .remove(id):
                    state.removeRemoteHost(id)
                case .cancel:
                    break
                }
                editing = nil
            }
        }
    }
}

/// Add or edit one remote machine.
private struct RemoteEditor: View {
    struct Draft: Identifiable {
        var id: String?
        var remote: RemoteEngine?
        var identity: String { id ?? "new" }
    }

    enum Result {
        case save(id: String?, RemoteEngine)
        case remove(String)
        case cancel
    }

    let draft: Draft
    let done: (Result) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var daemonPath = RemoteEngine.defaultDaemonPath
    @State private var useCustomCommand = false
    @State private var customCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if useCustomCommand {
                    TextField("Command", text: $customCommand, prompt: Text("ssh -T devbox '~/.jetline/bin/jetlined attach'"))
                        .font(.system(.body, design: .monospaced))
                } else {
                    TextField("SSH host", text: $host, prompt: Text("devbox or user@host"))
                    TextField("jetlined on the host", text: $daemonPath)
                        .font(.system(.body, design: .monospaced))
                }
                TextField("Name in the sidebar", text: $name, prompt: Text(suggestedName))
                Toggle("Use a custom command", isOn: $useCustomCommand)
                Text("Uses your ssh config and keys: `ssh -T <host> <jetlined> attach`. A custom command is any command whose stdin/stdout reach `jetlined attach`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                if let id = draft.id {
                    Button("Remove", role: .destructive) { done(.remove(id)) }
                }
                Spacer()
                Button("Cancel") { done(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Button(draft.id == nil ? "Add" : "Save") { done(.save(id: draft.id, remote)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
            .padding(16)
        }
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private var suggestedName: String {
        useCustomCommand ? Self.name(fromCommand: customCommand) : (host.nonBlank ?? "devbox")
    }

    private var isValid: Bool {
        useCustomCommand ? customCommand.nonBlank != nil : host.nonBlank != nil
    }

    private var remote: RemoteEngine {
        let displayName = name.nonBlank ?? suggestedName
        if useCustomCommand {
            return RemoteEngine(name: displayName, command: customCommand, sshHost: nil)
        }
        let path = daemonPath.trimmingCharacters(in: .whitespaces)
        var remote = RemoteEngine.ssh(
            host: host.trimmingCharacters(in: .whitespaces),
            daemonPath: path.isEmpty ? RemoteEngine.defaultDaemonPath : path
        )
        remote.name = displayName
        return remote
    }

    private func load() {
        guard let remote = draft.remote else { return }
        name = remote.name
        let path = Self.daemonPath(in: remote.command) ?? RemoteEngine.defaultDaemonPath
        if let sshHost = remote.sshHost, RemoteEngine.ssh(host: sshHost, daemonPath: path).command == remote.command {
            host = sshHost
            daemonPath = path
            useCustomCommand = false
        } else {
            customCommand = remote.command
            useCustomCommand = true
        }
    }

    private static func daemonPath(in command: String) -> String? {
        guard let range = command.range(of: " attach", options: .backwards) else { return nil }
        let head = command[..<range.lowerBound]
        guard let start = head.lastIndex(where: { $0 == " " || $0 == "'" }) else { return nil }
        return String(head[head.index(after: start)...])
    }

    static func name(fromCommand command: String) -> String {
        let words = command.split(separator: " ").map(String.init)
        if let i = words.firstIndex(of: "ssh") {
            if let host = words[(i + 1)...].first(where: { !$0.hasPrefix("-") }) { return host }
        }
        return words.first ?? "remote"
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
