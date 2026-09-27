import Foundation
import XCTest
@testable import JetlineApp

/// An exclusive run is queued behind the peers it displaces, so there is a
/// window where the run exists but no process does. The toolbar reads the
/// phase, so the queued run has to look started — and Stop has to call it
/// off rather than leave a task that spawns into a workspace the user has
/// already moved on from.
@MainActor
final class ScriptRunQueueTests: XCTestCase {
    func testQueuedRunIsDistinctFromStartingAndHasNoSurface() {
        let controller = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        controller.start(script: "true", cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertTrue(controller.isRunning, "a queued run should read as started")
        XCTAssertEqual(
            controller.phase,
            .queued,
            "queued is not starting — the peer still owns the port, so the panel must not claim Running"
        )
        XCTAssertNil(
            controller.terminal,
            "a queued run must hold no terminal, or the panel shows the run it is displacing"
        )
    }

    func testStopCancelsARunStillWaitingOnItsPeers() {
        let controller = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        controller.start(script: "true", cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }

        controller.stop()

        XCTAssertFalse(controller.isRunning, "Stop should take a queued run back to idle")
        XCTAssertNil(controller.terminal, "cancelling should not leave a spawned process")
    }

    func testDiscardCancelsARunStillWaitingOnItsPeers() {
        let controller = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        controller.start(script: "true", cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }

        controller.discard()

        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(controller.terminal)
    }

    /// Without a clearance the run spawns as it always did, so the queued
    /// path can't quietly become the only one that works.
    func testStopOnAQueuedRunLeavesItRestartable() {
        let controller = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        controller.start(script: "true", cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }
        controller.stop()

        controller.start(script: "true", cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertTrue(controller.isRunning, "a cancelled run should be startable again")
    }
}
