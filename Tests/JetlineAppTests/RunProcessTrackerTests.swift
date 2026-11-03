import XCTest
@testable import JetlineApp

final class RunProcessTrackerTests: XCTestCase {
    /// A run that ends on its own (a crashed dev server, a one-shot script)
    /// leaves nothing to follow; the tracker must not keep reading the whole
    /// process table every second for the life of the workspace.
    func testStopsPollingOnceTheRunHasExited() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 0.2"]
        try shell.run()
        let tracker = RunProcessTracker()
        tracker.track(root: shell.processIdentifier)
        await tracker.refresh()
        XCTAssertTrue(tracker.isPolling)
        shell.waitUntilExit()

        for _ in 0..<40 where tracker.isPolling {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(tracker.isPolling, "still polling after the run and everything it started exited")
    }
}
