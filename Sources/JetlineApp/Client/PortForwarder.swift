import Foundation
import Observation

/// Forwards a remote engine's listening ports to the same ports on this
/// Mac, the way VS Code's remote mode does: a dev server on the remote's
/// `127.0.0.1:3000` answers at `http://localhost:3000` here, with the
/// origin, cookies and CORS rules it would have locally.
///
/// Ports the user's own processes open on the remote are forwarded
/// automatically (see `ListeningPort.suggested`); others can be forwarded
/// by hand, and automatic ones switched off. A port that's taken on this
/// Mac isn't moved elsewhere — a different port would be a different
/// origin — it's reported instead, and retried.
///
/// Listeners stay up while the link is down, so a reconnect doesn't lose
/// the port to something else; connections made meanwhile are refused.
@MainActor
@Observable
final class PortForwarder {
    enum State: Equatable {
        case forwarding
        case failed(String)
        /// Detected and worth forwarding, but the user switched it off.
        case off
    }

    struct Entry: Identifiable, Equatable {
        var port: Int
        var process: String?
        var state: State
        /// Something is listening on it on the remote right now.
        var isListening: Bool
        var id: Int { port }
    }

    let hostId: String
    private(set) var hostName: String
    /// The remote's listening ports, as last reported.
    private(set) var remotePorts: [ListeningPort] = []
    /// False when the engine predates port forwarding.
    private(set) var isSupported = true
    /// The engine runs on this very Mac (a `jetlined` reached over
    /// `ssh localhost`, say): its ports are already here, and forwarding
    /// them would bind the port it's trying to reach — a loop.
    private(set) var isSameMachine = false

    var forwardsAutomatically: Bool {
        get { prefs.automatic }
        set {
            prefs.automatic = newValue
            savePrefs()
            reconcile()
        }
    }

    @ObservationIgnored private let persists: Bool
    private var prefs: Prefs
    @ObservationIgnored private var listeners: [Int: LoopbackListener] = [:]
    private var failures: [Int: String] = [:]
    @ObservationIgnored private let route = TunnelRoute()
    /// The pending retry; replacing or clearing it cancels that one.
    @ObservationIgnored private var retryToken: UUID?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let allowsSameMachine: Bool

    init(hostId: String, hostName: String, persists: Bool = true, allowsSameMachine: Bool = false) {
        self.hostId = hostId
        self.hostName = hostName
        self.persists = persists
        self.allowsSameMachine = allowsSameMachine
        self.prefs = persists ? Self.loadPrefs()[hostId] ?? Prefs() : Prefs()
        Self.registry.removeAll { $0.value == nil }
        Self.registry.append(Weak(value: self))
    }

    func rename(_ name: String) { hostName = name }

    // MARK: - What's forwarded

    /// Forwarded, failing, or switched off — what the sidebar lists.
    var entries: [Entry] {
        guard !isSameMachine else { return [] }
        let listening = Dictionary(remotePorts.map { ($0.port, $0) }, uniquingKeysWith: { a, _ in a })
        var ports = Set(prefs.manual)
        if prefs.automatic {
            ports.formUnion(remotePorts.filter(\.suggested).map(\.port))
        }
        return ports.sorted().map { port in
            let state: State
            if prefs.disabled.contains(port) {
                state = .off
            } else if let failure = failures[port] {
                state = .failed(failure)
            } else {
                state = .forwarding
            }
            return Entry(
                port: port,
                process: listening[port]?.process,
                state: state,
                isListening: listening[port] != nil
            )
        }
    }

    /// Listening on the remote but not in `entries`: offered in a menu.
    var otherPorts: [ListeningPort] {
        let shown = Set(entries.map(\.port))
        return remotePorts.filter { !shown.contains($0.port) }
    }

    /// Ports bound on this Mac right now.
    var forwardedPorts: [Int] { listeners.keys.sorted() }

    func forward(_ port: Int) {
        guard (1...65535).contains(port) else { return }
        prefs.disabled.remove(port)
        let suggested = remotePorts.contains { $0.port == port && $0.suggested }
        if !(suggested && prefs.automatic) { prefs.manual.insert(port) }
        savePrefs()
        reconcile()
    }

    func stopForwarding(_ port: Int) {
        prefs.manual.remove(port)
        if remotePorts.contains(where: { $0.port == port && $0.suggested }) {
            prefs.disabled.insert(port)
        }
        savePrefs()
        reconcile()
    }

    // MARK: - Link

    /// A fresh link to the engine: start watching its ports.
    func connected(_ client: EngineClient, _ hello: API.HelloResult) {
        generation += 1
        isSameMachine = !allowsSameMachine && hello.hostName == Platform.hostName
            && hello.homeDirectory == Platform.homeDirectory.path
        isSupported = hello.features?.contains(API.tunnelsFeature) == true
        guard isSupported, !isSameMachine else {
            route.mux = nil
            remotePorts = []
            reconcile()
            return
        }
        route.mux = client.tunnels()
        let generation = self.generation
        initialWatch = Task { [weak self] in
            // The reply is never older than an event that came before it.
            guard let ports = try? await client.call(API.WatchPorts()) else { return }
            guard let self, self.generation == generation else { return }
            self.received(ports)
        }
    }

    /// The first `ports.watch` after connecting (tests wait for it).
    @ObservationIgnored private(set) var initialWatch: Task<Void, Never>?

    func disconnected() {
        generation += 1
        route.mux = nil
    }

    /// Release every port (the host was removed).
    func stop() {
        disconnected()
        retryToken = nil
        remotePorts = []
        prefs = Prefs(automatic: false)
        for port in Array(listeners.keys) { release(port) }
        failures = [:]
    }

    /// A `.ports` event, or the reply to `ports.watch`.
    func received(_ ports: [ListeningPort]) {
        guard ports != remotePorts else { return }
        remotePorts = ports
        reconcile()
    }

    // MARK: - Listeners

    private var wanted: Set<Int> {
        guard isSupported, !isSameMachine else { return [] }
        return Set(entries.filter { $0.state != .off }.map(\.port))
    }

    private func reconcile() {
        let wanted = self.wanted
        for port in Array(listeners.keys) where !wanted.contains(port) { release(port) }
        for port in failures.keys where !wanted.contains(port) { failures[port] = nil }
        for port in wanted.sorted() where listeners[port] == nil { bind(port) }
        scheduleRetryIfNeeded()
    }

    private func bind(_ port: Int) {
        if let holder = Self.holder(of: port), holder !== self {
            setFailure(port, "Forwarded from \(holder.hostName)")
            return
        }
        let route = self.route
        do {
            listeners[port] = try LoopbackListener(port: port) { fd in
                if let mux = route.mux {
                    mux.open(fd: fd, port: port)
                } else {
                    // Link down: refuse rather than leave it hanging.
                    Glibc_or_Darwin_close(fd)
                }
            }
            setFailure(port, nil)
        } catch {
            setFailure(port, error.message)
        }
    }

    private func setFailure(_ port: Int, _ message: String?) {
        if failures[port] != message { failures[port] = message }
    }

    private func release(_ port: Int) {
        guard let listener = listeners.removeValue(forKey: port) else { return }
        listener.close()
        // Another remote may have been waiting for it.
        for other in Self.registry.compactMap(\.value) where other !== self && other.failures[port] != nil {
            other.reconcile()
        }
    }

    /// Every forwarder, so a second remote with the same port can say who
    /// has it here, and retry when it's let go.
    private struct Weak { weak var value: PortForwarder? }
    private static var registry: [Weak] = []

    private static func holder(of port: Int) -> PortForwarder? {
        registry.lazy.compactMap(\.value).first { $0.listeners[port] != nil }
    }

    /// Taken ports on this Mac free up without notice; try again now and then.
    private func scheduleRetryIfNeeded() {
        guard !failures.isEmpty else {
            retryToken = nil
            retryCount = 0
            return
        }
        guard retryToken == nil else { return }
        // Soon at first — a port just released can linger for a moment —
        // then at a relaxed pace.
        let delays: [DispatchTimeInterval] = [.milliseconds(500), .seconds(1), .seconds(2)]
        let delay = delays.dropFirst(retryCount).first ?? .seconds(5)
        retryCount += 1
        let token = UUID()
        retryToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.retryToken == token else { return }
                self.retryToken = nil
                self.reconcile()
            }
        }
    }

    // MARK: - Preferences

    private struct Prefs: Codable, Equatable {
        var automatic = true
        /// Forwarded by hand.
        var manual: Set<Int> = []
        /// Detected ones switched off.
        var disabled: Set<Int> = []
    }

    private static let prefsKey = "JetlinePortForwarding"

    private static func loadPrefs() -> [String: Prefs] {
        guard let data = UserDefaults.standard.data(forKey: prefsKey),
              let decoded = try? JSONDecoder().decode([String: Prefs].self, from: data) else { return [:] }
        return decoded
    }

    private func savePrefs() {
        guard persists else { return }
        var all = Self.loadPrefs()
        all[hostId] = prefs
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: Self.prefsKey)
        }
    }

    /// Forget a removed host's choices.
    static func forget(hostId: String) {
        var all = loadPrefs()
        guard all.removeValue(forKey: hostId) != nil, let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: prefsKey)
    }
}
