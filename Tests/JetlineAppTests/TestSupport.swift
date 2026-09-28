import XCTest
@testable import JetlineApp

enum TestSupport {
    /// A throwaway `JETLINE_DATA_DIR` for the whole test run, set before
    /// anything touches `Database.shared` — never the real ~/.jetline.
    /// realpath, not resolvingSymlinksInPath: the latter maps macOS's
    /// /private/var back to /var, and git reports the real path.
    static let dataDir: URL = {
        let tmp = realpath(FileManager.default.temporaryDirectory.path, nil).map { p in defer { free(p) }; return String(cString: p) }
            ?? FileManager.default.temporaryDirectory.path
        let dir = URL(fileURLWithPath: tmp).appendingPathComponent("jetline-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("JETLINE_DATA_DIR", dir.path, 1)
        return dir
    }()

    /// A fresh engine served over a socketpair — the path the Mac app and
    /// `jetlined` use — and a started client on the other end.
    @MainActor
    static func engineAndClient(
        tunnelConnect: EngineServer.TunnelConnect? = nil,
        onEvent: @escaping (EngineEvent) -> Void
    ) throws -> (EngineServer, EngineClient) {
        let server = EngineServer(engine: Engine(), engineVersion: "test", tunnelConnect: tunnelConnect)
        let (a, b) = try XCTUnwrap(Sockets.pair())
        server.accept(FramedConnection(readFD: a, writeFD: a, label: "test-server"))
        let client = EngineClient(connection: FramedConnection(readFD: b, writeFD: b, label: "test-client"))
        client.onEvent = onEvent
        client.start()
        return (server, client)
    }
}

/// Poll `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(20))
    }
}
