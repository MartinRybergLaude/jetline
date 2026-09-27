#if os(macOS)
import SwiftUI

/// Where the connect sheet was opened for: a new machine, or one already
/// in the sidebar (to fix or update it).
struct RemoteSetupRequest: Identifiable, Equatable {
    /// Nil for a new machine.
    var hostId: String?
    /// A new machine's ssh host, filled in (and checked) up front.
    var prefillHost: String?
    var id: String { hostId ?? "new" }
}

/// "Connect a Machine": the ssh host, a check of what's there, and —
/// when `jetlined` is missing or out of date — installing it, all in one
/// place. Adding the machine connects it; its repositories appear in the
/// sidebar as their own group.
struct ConnectRemoteSheet: View {
    @EnvironmentObject private var state: AppState
    let request: RemoteSetupRequest
    let dismiss: () -> Void

    @State private var host = ""
    @State private var name = ""
    @State private var daemonPath = RemoteEngine.defaultDaemonPath
    @State private var useCustomCommand = false
    @State private var customCommand = ""
    @State private var showAdvanced = false
    @State private var phase: Phase = .idle
    @State private var confirmRestart = false
    @State private var checkedHost: String?

    enum Phase: Equatable {
        case idle
        case checking
        case checked(RemoteInstaller.Probe)
        case failed(String)
        case working(String)
    }

    private var isNew: Bool { request.hostId == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "Connect a Machine" : "Set Up \(existingHost?.name ?? "Machine")")
                    .font(.title3.weight(.semibold))
                Text("Run workspaces on another computer over ssh. Its repositories get their own group in the sidebar, and everything there keeps running when this Mac sleeps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section {
                    if useCustomCommand {
                        TextField("Command", text: $customCommand, prompt: Text("ssh -T devbox '~/.jetline/bin/jetlined attach'"))
                            .font(.system(.body, design: .monospaced))
                    } else {
                        TextField("SSH host", text: $host, prompt: Text("devbox, or user@hostname"))
                            .onSubmit { check() }
                    }
                    TextField("Name in the sidebar", text: $name, prompt: Text(suggestedName))
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        if !useCustomCommand {
                            TextField("jetlined on the machine", text: $daemonPath)
                                .font(.system(.body, design: .monospaced))
                        }
                        Toggle("Use a custom command instead of ssh", isOn: $useCustomCommand)
                        Text("Any command whose stdin/stdout reach `jetlined attach`. Jetline can't check or install over a custom command.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    if !useCustomCommand {
                        Text("Uses your ssh config and keys, without a password prompt — set up key-based access first (`ssh-copy-id`).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !useCustomCommand {
                    Section("Machine") {
                        checkResults
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300)

            HStack {
                if let id = request.hostId {
                    Button("Remove", role: .destructive) {
                        state.removeRemoteHost(id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Connect" : "Save & Reconnect", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog("Restart the engine on \(host)?", isPresented: $confirmRestart) {
            Button("Restart", role: .destructive) { restart() }
        } message: {
            Text("The running engine is an older version. Restarting it ends the agents, terminals and run scripts it's running there; your worktrees and chats are kept.")
        }
    }

    // MARK: - Check results

    @ViewBuilder
    private var checkResults: some View {
        switch phase {
        case .idle:
            HStack {
                Text("Check the machine for jetlined and the tools it needs.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Check", action: check).disabled(host.nonBlank == nil)
            }
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(host)…").foregroundStyle(.secondary)
            }
        case let .working(message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(message).textSelection(.enabled)
                } icon: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
                Button("Check Again", action: check)
            }
        case let .checked(probe):
            probeRows(probe)
        }
    }

    @ViewBuilder
    private func probeRows(_ probe: RemoteInstaller.Probe) -> some View {
        row(ok: true, "Reachable — \(osLabel(probe.os)) \(probe.arch)")

        switch probe.os {
        case .linux:
            if !probe.isInstalled {
                HStack {
                    row(ok: false, "jetlined isn't installed")
                    Spacer()
                    Button("Install jetlined", action: install)
                }
            } else if !probe.isCurrent {
                HStack {
                    row(ok: probe.isCompatible, "jetlined \(probe.daemonVersion ?? "?") — this app is \(JetlineVersion.current)"
                        + (probe.isCompatible ? "" : " (incompatible)"))
                    Spacer()
                    Button("Update jetlined", action: install)
                }
            } else {
                row(ok: true, "jetlined \(probe.daemonVersion ?? "") installed")
            }
            if probe.isInstalled, probe.daemonRunning, !probe.isCurrent || installedThisSession {
                HStack {
                    Text(installedThisSession
                         ? "The running engine still has the old version."
                         : "An engine is running there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restart Engine…") { confirmRestart = true }
                }
            }
        case .macOS:
            if probe.macAppDaemon != nil {
                row(ok: true, "Jetline.app found — its built-in engine will be used")
            } else {
                row(ok: false, "Install Jetline on that Mac: its app contains the engine")
            }
        case .other:
            row(ok: false, "Jetline's engine runs on Linux and macOS only")
        }

        if probe.missingTools.isEmpty {
            row(ok: true, "git, gh, claude and codex are on its PATH")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                row(ok: false, "Not on its PATH: \(probe.missingTools.joined(separator: ", "))", warning: true)
                Text("Install what you use there (and log in: `gh auth login`, `claude`, `codex login`). Only git is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @State private var installedThisSession = false

    private func row(ok: Bool, _ text: String, warning: Bool = false) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : (warning ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                .foregroundStyle(ok ? Color.green : (warning ? Color.orange : Color.red))
        }
    }

    private func osLabel(_ os: RemoteInstaller.Probe.OS) -> String {
        switch os {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case let .other(name): return name
        }
    }

    // MARK: - Actions

    private var existingHost: EngineHost? {
        request.hostId.flatMap { state.host(id: $0) }
    }

    private var suggestedName: String {
        if useCustomCommand {
            let words = customCommand.split(separator: " ").map(String.init)
            if let i = words.firstIndex(of: "ssh"), let h = words[(i + 1)...].first(where: { !$0.hasPrefix("-") }) { return h }
            return "remote"
        }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "devbox" }
        // user@host → host
        return trimmed.split(separator: "@").last.map(String.init) ?? trimmed
    }

    private var canSave: Bool {
        switch phase {
        case .checking, .working: return false
        default: break
        }
        return useCustomCommand ? customCommand.nonBlank != nil : host.nonBlank != nil
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
        if let prefill = request.prefillHost {
            host = prefill
            check()
            return
        }
        guard let host = existingHost, case let .remote(remote) = host.connection.target else { return }
        name = remote.name
        if let sshHost = remote.sshHost {
            self.host = sshHost
            if let range = remote.command.range(of: " attach", options: .backwards) {
                // The daemon part of `ssh … <host> '<daemon> attach'`.
                let head = remote.command[..<range.lowerBound]
                if let quote = head.lastIndex(of: "'") {
                    daemonPath = String(head[head.index(after: quote)...])
                } else if let space = head.lastIndex(of: " ") {
                    daemonPath = String(head[head.index(after: space)...])
                }
            }
            check()
        } else {
            customCommand = remote.command
            useCustomCommand = true
            showAdvanced = true
        }
    }

    private func check() {
        let target = host.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !useCustomCommand else { return }
        phase = .checking
        checkedHost = target
        let path = daemonPath
        Task {
            do {
                var probe = try await RemoteInstaller.probe(host: target, daemonPath: path)
                // A Mac host serves from its Jetline.app.
                if probe.os == .macOS, probe.macAppDaemon != nil, daemonPath == RemoteEngine.defaultDaemonPath {
                    daemonPath = RemoteInstaller.macDaemonCommand
                    probe = try await RemoteInstaller.probe(host: target, daemonPath: daemonPath)
                }
                guard checkedHost == target else { return }
                phase = .checked(probe)
                #if DEBUG
                // `-JetlineConnectAutoInstall YES`: drive the whole flow
                // (install if needed, then connect) for scripted testing.
                if UserDefaults.standard.bool(forKey: "JetlineConnectAutoInstall"), isNew {
                    if probe.os == .linux, !probe.isCurrent { install() } else { save() }
                }
                #endif
            } catch {
                guard checkedHost == target else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func install() {
        guard case let .checked(probe) = phase else { return }
        let target = host.trimmingCharacters(in: .whitespaces)
        let path = daemonPath
        phase = .working("Preparing…")
        Task {
            do {
                try await RemoteInstaller.install(host: target, daemonPath: path, arch: probe.arch) { message in
                    phase = .working(message)
                }
                installedThisSession = true
                let fresh = try await RemoteInstaller.probe(host: target, daemonPath: path)
                phase = .checked(fresh)
                #if DEBUG
                if UserDefaults.standard.bool(forKey: "JetlineConnectAutoInstall"), isNew, fresh.isCurrent { save() }
                #endif
                // Nothing running yet: the next connection starts the new one.
                if !fresh.daemonRunning, let host = existingHost { host.connection.reconnectNow() }
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func restart() {
        let target = host.trimmingCharacters(in: .whitespaces)
        let path = daemonPath
        phase = .working("Restarting the engine…")
        Task {
            do {
                try await RemoteInstaller.restartEngine(host: target, daemonPath: path)
                installedThisSession = false
                phase = .checked(try await RemoteInstaller.probe(host: target, daemonPath: path))
                existingHost?.connection.reconnectNow()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        if let id = request.hostId {
            state.updateRemoteHost(id, remote: remote)
            state.host(id: id)?.connection.reconnectNow()
        } else {
            state.addRemoteHost(remote)
        }
        dismiss()
    }
}
#endif
