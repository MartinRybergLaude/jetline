import Foundation

/// The client end of a Jetline connection: typed requests, the engine's
/// event stream, and terminal output routing. Platform-neutral — the Mac app
/// builds its mirror on it, and the integration tests drive an engine with
/// it directly.
///
/// Frames are decoded off the main thread; events and terminal output are
/// delivered on the main actor in arrival order.
@MainActor
final class EngineClient {
    private let connection: FramedConnection
    private let encoder = Wire.makeEncoder()
    private let pending = PendingRequests()
    private var nextId: UInt64 = 1
    private var terminalHandlers: [String: (UInt64, Data) -> Void] = [:]
    /// Forwarded connections, once `startTunnels` set them up.
    private let tunnelRoute = TunnelRoute()
    private(set) var isClosed = false

    /// Engine events, in order.
    var onEvent: ((EngineEvent) -> Void)?
    /// The connection went away (the engine quit, ssh dropped, …).
    var onClose: (() -> Void)?

    init(connection: FramedConnection) {
        self.connection = connection
    }

    func start() {
        let pending = self.pending
        let decoder = Wire.makeDecoder()
        let tunnelRoute = self.tunnelRoute
        connection.onFrames = { [weak self] frames in
            var deliveries: [@MainActor (EngineClient) -> Void] = []
            for frame in frames {
                if frame.kind.isTunnel {
                    tunnelRoute.mux?.receive(frame.kind, frame.payload)
                    continue
                }
                switch frame.kind {
                case .message:
                    guard let head = try? decoder.decode(Wire.ServerHead.self, from: frame.payload) else { continue }
                    if head.type == "response", let id = head.id {
                        // In order with the events around it: code after an
                        // `await call(...)` must see the events the engine
                        // sent before its response.
                        let payload = frame.payload
                        deliveries.append { _ in pending.complete(id, with: payload) }
                    } else if head.type == "event" {
                        do {
                            let event = try decoder.decode(Wire.Event.self, from: frame.payload).event
                            deliveries.append { $0.onEvent?(event) }
                        } catch {
                            FileHandle.standardError.write(Data("jetline: undecodable event: \(error)\n".utf8))
                        }
                    }
                case .terminalOutput:
                    guard let (id, offset, bytes) = TerminalFrame.parseOutput(frame.payload) else { continue }
                    deliveries.append { $0.terminalHandlers[id]?(offset, bytes) }
                case .terminalInput, .tunnelOpen, .tunnelData, .tunnelClose, .tunnelAck:
                    continue
                }
            }
            guard !deliveries.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for delivery in deliveries { delivery(self) }
                }
            }
        }
        connection.onClose = { [weak self] in
            tunnelRoute.mux?.close()
            pending.failAll(WireError.disconnected)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    self.isClosed = true
                    self.onClose?()
                }
            }
        }
        connection.start()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pending.failAll(WireError.disconnected)
        connection.close()
    }

    /// Send a request and wait for its response.
    func call<R: RPC>(_ request: R) async throws -> R.Response {
        guard !isClosed else { throw WireError.disconnected }
        let id = nextId
        nextId += 1
        let data = try encoder.encode(Wire.Request(id: id, method: R.method, params: request))
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<R.Response, Error>) in
            pending.register(id) { payload, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                do {
                    let body = try Wire.makeDecoder().decode(Wire.ResponseBody<R.Response>.self, from: payload ?? Data())
                    if let error = body.error {
                        continuation.resume(throwing: error)
                    } else if let result = body.result {
                        continuation.resume(returning: result)
                    } else if let optional = R.Response.self as? any OptionalResponse.Type,
                              let none = optional.nilValue as? R.Response {
                        // An optional result type whose value was nil.
                        continuation.resume(returning: none)
                    } else {
                        continuation.resume(throwing: WireError("The engine sent an empty response to \(R.method)."))
                    }
                } catch {
                    continuation.resume(throwing: WireError("Couldn't read the engine's response to \(R.method): \(error)"))
                }
            }
            connection.send(.message, data)
        }
    }

    /// Fire and forget; failures are dropped.
    func send<R: RPC>(_ request: R) {
        Task { _ = try? await call(request) }
    }

    // MARK: Tunnels

    /// The multiplexer for connections forwarded to the engine's machine
    /// (created on first use). Only for engines whose hello lists
    /// `API.tunnelsFeature`.
    func tunnels() -> TunnelMux {
        if let mux = tunnelRoute.mux { return mux }
        let connection = self.connection
        let mux = TunnelMux(label: "client") { kind, payload in connection.send(kind, payload) }
        if isClosed { mux.close() }
        tunnelRoute.mux = mux
        return mux
    }

    // MARK: Terminals

    func setTerminalHandler(_ id: String, _ handler: ((UInt64, Data) -> Void)?) {
        terminalHandlers[id] = handler
    }

    func sendTerminalInput(_ id: String, _ bytes: Data) {
        guard !isClosed, !bytes.isEmpty else { return }
        connection.send(.terminalInput, TerminalFrame.input(id: id, bytes: bytes))
    }
}

/// Request id → completion, touched from the read queue and the main actor.
private final class PendingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UInt64: @Sendable (Data?, Error?) -> Void] = [:]
    private var failed: Error?

    func register(_ id: UInt64, _ handler: @escaping @Sendable (Data?, Error?) -> Void) {
        let error: Error? = lock.withLock {
            if let failed { return failed }
            handlers[id] = handler
            return nil
        }
        if let error { handler(nil, error) }
    }

    func complete(_ id: UInt64, with payload: Data) {
        let handler = lock.withLock { handlers.removeValue(forKey: id) }
        handler?(payload, nil)
    }

    func failAll(_ error: Error) {
        let all: [@Sendable (Data?, Error?) -> Void] = lock.withLock {
            failed = error
            defer { handlers.removeAll() }
            return Array(handlers.values)
        }
        for handler in all { handler(nil, error) }
    }
}

/// Lets `call` recognise an optional response type, whose nil arrives as
/// `"result": null`.
private protocol OptionalResponse {
    static var nilValue: Self { get }
}

extension Optional: OptionalResponse {
    static var nilValue: Optional { nil }
}
