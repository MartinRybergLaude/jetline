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

    // MARK: Lifecycle, with real processes

    private var cwd: String { TestSupport.dataDir.path }

    func testABlankSetupScriptFinishesAtOnce() {
        let setup = ScriptRun(kind: .setup, workspaceId: "ws", settings: { AppSettings() })
        XCTAssertEqual(setup.phase, .running, "setup starts out running")
        setup.start(script: "  \n ", cwd: cwd, env: [:])
        XCTAssertEqual(setup.phase, .finished)
        XCTAssertEqual(setup.exitStatus, 0)
        XCTAssertNil(setup.terminal)
        XCTAssertFalse(setup.isRunning)
    }

    func testSetupFinishesWithTheScriptsExitStatus() async {
        let setup = ScriptRun(kind: .setup, workspaceId: "ws", settings: { AppSettings() })
        setup.start(script: "echo installing; exit 4", cwd: cwd, env: [:])
        XCTAssertEqual(setup.phase, .running)
        XCTAssertNotNil(setup.terminal)
        await eventually("setup finished", timeout: 15) { setup.phase == .finished }
        XCTAssertEqual(setup.exitStatus, 4)
        XCTAssertEqual(setup.info.terminalId, setup.terminal?.id, "the transcript stays viewable")
    }

    func testARunThatExitsGoesBackToIdleWithItsStatus() async {
        let run = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        run.start(script: "exit 3", cwd: cwd, env: [:])
        XCTAssertEqual(run.phase, .starting)
        await eventually("idle", timeout: 15) { run.phase == .idle }
        XCTAssertEqual(run.exitStatus, 3)
        XCTAssertFalse(run.isRunning)
    }

    func testALongRunBecomesRunningIgnoresASecondStartAndStops() async {
        let run = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        run.start(script: "echo $JL_TEST_VAR; sleep 30", cwd: cwd, env: ["JL_TEST_VAR": "from-env"])
        let terminal = run.terminal
        await eventually("running", timeout: 10) { run.phase == .running }
        run.start(script: "echo second", cwd: cwd, env: [:])
        XCTAssertTrue(run.terminal === terminal, "a second start doesn't replace a live run")
        await eventually("env reached the script", timeout: 10) {
            String(decoding: terminal?.buffer.read(from: nil).bytes ?? Data(), as: UTF8.self).contains("from-env")
        }
        await run.stopAndWait()
        await eventually("idle", timeout: 10) { run.phase == .idle }
        XCTAssertNotNil(run.exitStatus)
    }

    func testAQueuedRunStartsOnceItsClearanceResolves() async {
        let run = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        var cleared = false
        run.start(script: "exit 0", cwd: cwd, env: [:]) {
            try? await Task.sleep(for: .milliseconds(100))
            cleared = true
        }
        XCTAssertEqual(run.phase, .queued)
        await eventually("spawned after clearance", timeout: 10) { run.terminal != nil }
        XCTAssertTrue(cleared)
        await eventually("finished", timeout: 15) { run.phase == .idle }
        XCTAssertEqual(run.exitStatus, 0)
    }
}
