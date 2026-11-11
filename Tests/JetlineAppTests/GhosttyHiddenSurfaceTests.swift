#if os(macOS)
import AppKit
import GhosttyTerminal
import XCTest
@testable import JetlineApp

@MainActor
final class GhosttyHiddenSurfaceTests: XCTestCase {
    func testHiddenSurfaceKeepsTakingOutputThatMessagesTheApp() async throws {
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.controller = TerminalController()
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session), context: .window)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let deadline = Date().addingTimeInterval(10)
        while session.readViewportText() == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try XCTSkipIf(session.readViewportText() == nil, "no ghostty surface in this environment")
        view.setSurfaceVisible(false)
        try await Task.sleep(for: .milliseconds(100))

        let watchdog = Watchdog(seconds: 10)
        for _ in 0..<200 {
            session.receive(Data("\u{1B}[?1003h\u{1B}[?1003l".utf8))
        }
        watchdog.disarm()
        session.receive(Data("done".utf8))
        XCTAssertTrue(session.readViewportText()?.contains("done") == true)
    }
}

private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = true

    init(seconds: TimeInterval) {
        Thread.detachNewThread { [self] in
            Thread.sleep(forTimeInterval: seconds)
            if lock.withLock({ armed }) {
                fatalError("main thread wedged writing to a hidden ghostty surface")
            }
        }
    }

    func disarm() {
        lock.withLock { armed = false }
    }
}
#endif
