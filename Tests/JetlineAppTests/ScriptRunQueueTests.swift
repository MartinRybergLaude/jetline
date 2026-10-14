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
        controller.startRun(script: "true", stopScript: nil, cwd: NSTemporaryDirectory(), env: [:]) {
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
        controller.startRun(script: "true", stopScript: nil, cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }

        controller.stop()

        XCTAssertFalse(controller.isRunning, "Stop should take a queued run back to idle")
        XCTAssertNil(controller.terminal, "cancelling should not leave a spawned process")
    }

    func testDiscardCancelsARunStillWaitingOnItsPeers() {
        let controller = ScriptRun(kind: .run, workspaceId: "ws", settings: { AppSettings() })
        controller.startRun(script: "true", stopScript: nil, cwd: NSTemporaryDirectory(), env: [:]) {
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
        controller.startRun(script: "true", stopScript: nil, cwd: NSTemporaryDirectory(), env: [:]) {
            try? await Task.sleep(for: .seconds(60))
        }
        controller.stop()

        controller.startRun(script: "true", stopScript: nil, cwd: NSTemporaryDirectory(), env: [:]) {
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
        run.startRun(script: "exit 0", stopScript: nil, cwd: cwd, env: [:]) {
            try? await Task.sleep(for: .milliseconds(100))
            cleared = true
        }
        XCTAssertEqual(run.phase, .queued)
        await eventually("spawned after clearance", timeout: 10) { run.terminal != nil }
        XCTAssertTrue(cleared)
        await eventually("finished", timeout: 15) { run.phase == .idle }
        XCTAssertEqual(run.exitStatus, 0)
    }

    // MARK: Cleanup

    /// `nohup … &` leaves the PTY's process groups; Stop still has to take
    /// it down, then run the stop script.
    func testStopKillsDetachedProcessesAndRunsTheStopScript() async throws {
        let dir = URL(fileURLWithPath: cwd).appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let run = ScriptRun(kind: .run, workspaceId: "ws-\(UUID().uuidString)", settings: { AppSettings() })
        run.startRun(
            script: "nohup sh -c 'trap \"\" HUP TERM; sleep 300' >/dev/null 2>&1 & echo $! > pid; sleep 300",
            stopScript: "touch stopped",
            cwd: dir.path,
            env: [:]
        )
        await eventually("running", timeout: 15) { run.phase == .running }
        let pidFile = dir.appendingPathComponent("pid")
        await eventually("pid written", timeout: 10) { FileManager.default.fileExists(atPath: pidFile.path) }
        let pid = try XCTUnwrap(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), 0, "the detached process is alive")

        await run.stopAndWait()

        XCTAssertEqual(run.phase, .idle)
        XCTAssertNotEqual(kill(pid, 0), 0, "Stop should reach the detached process")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("stopped").path), "the stop script ran")
    }

    /// Shaped like a real dev script: services in process groups of their
    /// own, and an exit trap that takes a while tearing things down. Stop
    /// has to let the trap finish — killing it partway is what left
    /// containers running — and output from it still reaches the panel.
    func testStopLetsTheScriptsExitTrapFinish() async throws {
        let dir = URL(fileURLWithPath: cwd).appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = """
        #!/usr/bin/env bash
        pids=()
        cleanup() {
          trap - INT TERM EXIT
          for pid in "${pids[@]}"; do kill -TERM -- "-$pid" 2>/dev/null || true; done
          echo tearing down
          sleep 4
          touch cleaned
        }
        trap cleanup INT TERM EXIT
        set -m
        (sleep 300) &
        pids+=("$!")
        echo $! > service
        set +m
        wait
        """
        try script.write(to: dir.appendingPathComponent("dev.sh"), atomically: true, encoding: .utf8)
        let run = ScriptRun(kind: .run, workspaceId: "ws-\(UUID().uuidString)", settings: { AppSettings() })
        run.startRun(script: "bash dev.sh", stopScript: nil, cwd: dir.path, env: [:])
        await eventually("running", timeout: 15) { run.phase == .running }
        await eventually("service up", timeout: 10) { FileManager.default.fileExists(atPath: dir.appendingPathComponent("service").path) }

        await run.stopAndWait()

        XCTAssertEqual(run.phase, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cleaned").path), "the exit trap ran to the end")
        let transcript = String(decoding: run.terminal?.buffer.read(from: nil).bytes ?? Data(), as: UTF8.self)
        XCTAssertTrue(transcript.contains("tearing down"), "the trap's output is shown")
    }

    /// A run that ended on its own wasn't cleaned up; the next start does
    /// it first.
    func testARunThatEndedOnItsOwnIsCleanedUpBeforeTheNext() async throws {
        let dir = URL(fileURLWithPath: cwd).appendingPathComponent("cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let run = ScriptRun(kind: .run, workspaceId: "ws-\(UUID().uuidString)", settings: { AppSettings() })
        run.startRun(script: "exit 0", stopScript: "echo x >> stops", cwd: dir.path, env: [:])
        await eventually("first run done", timeout: 15) { run.phase == .idle && run.exitStatus == 0 }
        run.startRun(script: "exit 0", stopScript: "echo x >> stops", cwd: dir.path, env: [:])
        await eventually("second run done", timeout: 15) { run.phase == .idle && run.exitStatus == 0 }
        let stops = try String(contentsOf: dir.appendingPathComponent("stops"), encoding: .utf8)
        XCTAssertEqual(stops.split(separator: "\n").count, 2, "cleanup before the first run (after launch) and before the second")
    }
}
