#if os(macOS)
import SwiftUI

/// Settings → Remote: run the engine on this Mac, or connect to `jetlined`
/// on another machine over ssh.
struct EngineSettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var mode: Mode = .local
    @State private var host = ""
    @State private var daemonPath = RemoteEngine.defaultDaemonPath
    @State private var useCustomCommand = false
    @State private var customCommand = ""

    enum Mode: Hashable { case local, remote }

    var body: some View {
        Form {
            Section {
                Picker("Run workspaces on", selection: $mode) {
                    Text("This Mac").tag(Mode.local)
                    Text("A remote machine").tag(Mode.remote)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("On a remote machine, Jetline's engine (`jetlined`) runs the git worktrees, agents, terminals and run scripts there. This app is only the window onto it: closing the laptop leaves everything running, and the next connection picks up where you left off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mode == .remote {
                Section("Connection") {
                    if useCustomCommand {
                        TextField("Command", text: $customCommand, prompt: Text("ssh -T devbox '~/.jetline/bin/jetlined attach'"))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        TextField("SSH host", text: $host, prompt: Text("devbox or user@host"))
                        TextField("jetlined on the host", text: $daemonPath)
                            .font(.system(.body, design: .monospaced))
                    }
                    Toggle("Use a custom command", isOn: $useCustomCommand)
                }
                Section {
                    Text("Uses your ssh config and keys (`ssh -T <host> <jetlined> attach`); the host needs `git`, `gh` and the agent CLIs on its PATH. Install the daemon on it with `make deploy-daemon HOST=<host>` from a Jetline checkout.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    EngineStatusLabel(connection: state.connection)
                    Spacer()
                    if isDirty {
                        Button("Connect") { apply() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!isValid)
                    } else if case .reconnecting = state.connection.status {
                        Button("Retry now") { state.connection.reconnectNow() }
                    } else if case .failed = state.connection.status {
                        Button("Retry") { state.connection.reconnectNow() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadFromTarget)
    }

    private var draftTarget: EngineTarget {
        switch mode {
        case .local:
            return .local
        case .remote:
            if useCustomCommand {
                return .remote(RemoteEngine(name: Self.name(fromCommand: customCommand), command: customCommand, sshHost: nil))
            }
            let path = daemonPath.trimmingCharacters(in: .whitespaces)
            return .remote(RemoteEngine.ssh(
                host: host.trimmingCharacters(in: .whitespaces),
                daemonPath: path.isEmpty ? RemoteEngine.defaultDaemonPath : path
            ))
        }
    }

    private var isValid: Bool {
        switch mode {
        case .local: return true
        case .remote: return useCustomCommand ? customCommand.nonBlank != nil : host.nonBlank != nil
        }
    }

    private var isDirty: Bool { draftTarget != state.connection.target }

    private func apply() {
        state.switchEngine(to: draftTarget)
    }

    private func loadFromTarget() {
        switch state.connection.target {
        case .local:
            mode = .local
        case let .remote(remote):
            mode = .remote
            if let sshHost = remote.sshHost, RemoteEngine.ssh(host: sshHost, daemonPath: Self.daemonPath(in: remote.command) ?? RemoteEngine.defaultDaemonPath) == remote {
                host = sshHost
                daemonPath = Self.daemonPath(in: remote.command) ?? RemoteEngine.defaultDaemonPath
                useCustomCommand = false
            } else {
                customCommand = remote.command
                useCustomCommand = true
            }
        }
    }

    private static func daemonPath(in command: String) -> String? {
        guard let range = command.range(of: " attach", options: .backwards) else { return nil }
        let head = command[..<range.lowerBound]
        guard let start = head.lastIndex(where: { $0 == " " || $0 == "'" }) else { return nil }
        return String(head[head.index(after: start)...])
    }

    private static func name(fromCommand command: String) -> String {
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

/// Sidebar footer line for a remote engine, so it's always clear where
/// the workspaces live — and when the link is down.
struct EngineStatusPill: View {
    let connection: EngineConnection

    var body: some View {
        if !(connection.isLocal && connection.status == .connected) {
            HStack(spacing: 8) {
                EngineStatusLabel(connection: connection)
                Spacer(minLength: 0)
                if case .reconnecting = connection.status {
                    Button("Retry") { connection.reconnectNow() }
                        .controlSize(.small)
                } else if case .failed = connection.status {
                    Button("Retry") { connection.reconnectNow() }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}
#endif
