#if os(macOS)
import Foundation
import Observation

/// One engine the app is connected to — this Mac's own, or a `jetlined` on
/// another machine — with its mirror of that engine's app-wide state. The
/// sidebar shows one group per host; everything a workspace does is routed
/// to the host that owns it. Hosts connect independently: a remote being
/// down only greys out its own group.
@MainActor
@Observable
final class EngineHost: Identifiable {
    /// `"local"`, or the remote's configuration id.
    let id: String
    private(set) var name: String
    let connection: EngineConnection
    let files: EngineFiles
    /// The remote's ports, forwarded to this Mac. Nil for this Mac itself.
    let ports: PortForwarder?

    // Mirror of the engine's GlobalSnapshot.
    var repositories: [Repository] = []
    var workspacesByRepo: [String: [Workspace]] = [:]
    var repoMetadataByRepo: [String: RepoIdentifier] = [:]
    var prTrackerStatus: PRTrackerStatus = .ok
    var settings: AppSettings?
    /// The mirror is current: false before the first sync and while the
    /// link is down.
    var isSynced = false

    static let localId = "local"

    init(id: String, name: String, target: EngineTarget) {
        self.id = id
        self.name = name
        self.connection = EngineConnection(target: target)
        self.files = EngineFiles(connection: connection)
        // Test remotes from the environment don't touch saved choices.
        self.ports = id == Self.localId ? nil : PortForwarder(hostId: id, hostName: name, persists: !id.hasPrefix("env"))
    }

    var isLocal: Bool { id == Self.localId }

    /// For editors that open a folder over ssh.
    var sshHost: String? {
        if case let .remote(remote) = connection.target { return remote.sshHost }
        return nil
    }

    func rename(_ name: String) { self.name = name }

    /// Whether `workspaceId` (a worktree workspace or a repo's base
    /// checkout) belongs to this host.
    func owns(workspaceId: String) -> Bool {
        if workspaceId.hasPrefix(Engine.repositoryBaseWorkspacePrefix) {
            let repoId = String(workspaceId.dropFirst(Engine.repositoryBaseWorkspacePrefix.count))
            return repositories.contains { $0.id == repoId }
        }
        return workspacesByRepo.values.contains { $0.contains { $0.id == workspaceId } }
    }

    func owns(repoId: String) -> Bool {
        repositories.contains { $0.id == repoId }
    }
}

/// A remote the user added (Settings → Remote), persisted in the app's
/// defaults. The local host isn't stored: it's always there.
struct RemoteHostConfig: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var remote: RemoteEngine
}

enum RemoteHostStore {
    private static let key = "JetlineRemoteHosts"
    /// Single-remote setting from before hosts were a list.
    private static let legacyKey = "JetlineEngineTarget"

    static func load() -> [RemoteHostConfig] {
        var hosts: [RemoteHostConfig] = []
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([RemoteHostConfig].self, from: data) {
            hosts = decoded
        } else if let data = UserDefaults.standard.data(forKey: legacyKey),
                  let target = try? JSONDecoder().decode(EngineTarget.self, from: data),
                  case let .remote(remote) = target {
            hosts = [RemoteHostConfig(id: UUID().uuidString, remote: remote)]
            save(hosts)
        }
        // For testing, not persisted: JETLINE_REMOTE_HOSTS is a JSON array of
        // {"name": …, "command": …} to use instead; JETLINE_REMOTE_COMMAND
        // adds one more.
        let env = ProcessInfo.processInfo.environment
        if let json = env["JETLINE_REMOTE_HOSTS"], let data = json.data(using: .utf8),
           let remotes = try? JSONDecoder().decode([RemoteEngine].self, from: data) {
            hosts = remotes.enumerated().map { RemoteHostConfig(id: "env-\($0.offset)", remote: $0.element) }
            // The saved list isn't loaded, so it mustn't be overwritten either.
            overridden = true
        }
        if let command = env["JETLINE_REMOTE_COMMAND"], !command.isEmpty {
            let name = env["JETLINE_REMOTE_NAME"] ?? "remote"
            hosts.append(RemoteHostConfig(id: "env", remote: RemoteEngine(name: name, command: command)))
        }
        return hosts
    }

    nonisolated(unsafe) private static var overridden = false

    static func save(_ hosts: [RemoteHostConfig]) {
        guard !overridden else { return }
        let persisted = hosts.filter { !$0.id.hasPrefix("env") }
        if let data = try? JSONEncoder().encode(persisted) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
#endif
