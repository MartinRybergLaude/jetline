import Foundation
import XCTest
@testable import JetlineApp

/// Termination has to reach the whole tree the run script started, not just
/// the shell hosting it. Two regressions hid here at once: the interactive
/// login shell (`zsh -i`) turns on job control and runs the script in a
/// process group of its own, and SIGHUP alone is advisory. The result was a
/// Stop (or an exclusive run displacing a peer) that flipped the UI to idle
/// while the dev server kept its port.
final class PTYProcessTerminationTests: XCTestCase {
    /// Closing a tab drops the terminal, and with it the last reference to
    /// its `PTYProcess`, right after `terminate()`. The master fd and the
    /// child's exit status must still be collected, or every closed tab
    /// leaves a descriptor open and a zombie behind for the daemon's life.
    func testTerminateReleasesTheChildWithNoOneHoldingTheProcess() throws {
        let exited = expectation(description: "exit reported")
        var pid: pid_t = 0
        var master: Int32 = -1
        do {
            let process = PTYProcess(
                executable: "/bin/sh",
                args: ["-c", "sleep 30"],
                cwd: NSTemporaryDirectory(),
                env: ProcessInfo.processInfo.environment,
                output: { _ in },
                exit: { _ in exited.fulfill() }
            )
            try process.start()
            pid = process.pid
            master = process.masterDescriptor
            process.terminate()
        }
        wait(for: [exited], timeout: 10)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1, "the child was left unreaped")
        XCTAssertEqual(fcntl(master, F_GETFD), -1, "the master fd was left open")
    }

    /// A paste into a program that isn't reading its input fills the tty
    /// and the write waits for room. It must not hold up `terminate()`
    /// (queued behind it), or the tab never goes away.
    func testTerminateIsNotStuckBehindAWriteNobodyReads() throws {
        let exited = expectation(description: "exit reported")
        let process = PTYProcess(
            executable: "/bin/sh",
            args: ["-c", "stty raw -echo; sleep 30"],
            cwd: NSTemporaryDirectory(),
            env: ProcessInfo.processInfo.environment,
            output: { _ in },
            exit: { _ in exited.fulfill() }
        )
        try process.start()
        usleep(200_000)
        process.write(Data(repeating: 0x61, count: 256 * 1024))
        process.write(Data(repeating: 0x62, count: 256 * 1024))
        usleep(200_000)
        process.terminate()
        wait(for: [exited], timeout: 8)
    }

    /// The shape that leaked: an interactive login shell, a job in a process
    /// group of its own, and a process that ignores SIGHUP.
    func testTerminateKillsJobGroupIgnoringSIGHUP() throws {
        let marker = try makeMarkerFile()
        // `trap '' HUP` before the exec, so the process that replaces the
        // wrapper inherits SIG_IGN and SIGHUP alone cannot end it.
        let process = try startShell(trappingHangup: true, marker: marker)
        addTeardownBlock { Self.forceKill(matching: marker) }

        XCTAssertTrue(waitForJob(marker, toExist: true), "run script never started")
        let job = try XCTUnwrap(Self.jobProcesses(matching: marker).first)
        XCTAssertNotEqual(
            job.group,
            process.pid,
            "job should be in its own process group — the case terminate() has to cover"
        )

        process.terminate()

        XCTAssertTrue(
            waitForJob(marker, toExist: false, timeout: 8),
            "SIGHUP-ignoring job survived terminate() — it would still hold its port"
        )
    }

    /// The completion is what an exclusive run waits on before binding the
    /// port its peer was holding, so it must not fire while anything the
    /// terminal started is still alive.
    func testTerminateCompletionWaitsForTheJobToDie() throws {
        let marker = try makeMarkerFile()
        let process = try startShell(trappingHangup: true, marker: marker)
        addTeardownBlock { Self.forceKill(matching: marker) }

        XCTAssertTrue(waitForJob(marker, toExist: true), "run script never started")

        let settled = expectation(description: "termination settled")
        let survivors = Counter()
        process.terminate {
            survivors.value = Self.jobProcesses(matching: marker).count
            settled.fulfill()
        }
        wait(for: [settled], timeout: 10)

        XCTAssertEqual(
            survivors.value,
            0,
            "completion fired while the job was still alive — the port would still be taken"
        )
    }

    /// A job that does handle SIGHUP should die on the signal, well before
    /// the SIGKILL that backs it up. Guards against "fixing" the leak by
    /// leaning on the escalation and losing graceful shutdown.
    func testTerminateHangsUpBeforeEscalating() throws {
        let marker = try makeMarkerFile()
        let process = try startShell(trappingHangup: false, marker: marker)
        addTeardownBlock { Self.forceKill(matching: marker) }

        XCTAssertTrue(waitForJob(marker, toExist: true), "run script never started")

        let start = Date()
        process.terminate()
        XCTAssertTrue(waitForJob(marker, toExist: false, timeout: 8))
        XCTAssertLessThan(
            Date().timeIntervalSince(start),
            1.5,
            "job outlived the SIGHUP and only died to the SIGKILL escalation"
        )
    }

    // MARK: - Helpers

    private struct JobProcess {
        var pid: pid_t
        var group: pid_t
    }

    /// Carries one reading out of the termination completion, which fires
    /// off the io queue rather than on the test's thread.
    private final class Counter: @unchecked Sendable {
        var value: Int?
    }

    /// Path for the job to `tail -f`, used as the marker `ps` is searched
    /// for. It reaches the script through the environment rather than the
    /// script text: the shell's own argv is the unexpanded source, so a
    /// literal path there would match the shell (and the strays a `.zshrc`
    /// leaves behind) instead of the job we are actually watching.
    private func makeMarkerFile() throws -> String {
        let path = NSTemporaryDirectory()
            .appending("jetline-pty-test-\(UUID().uuidString.prefix(8))")
        try Data().write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// Spawn the way `RunController` does: the user's shell through
    /// `ShellScriptLauncher`, on a real pty so job control is in play. The
    /// trailing `; true` keeps zsh from exec'ing itself into the job, which
    /// is what gives the job a process group of its own.
    private func startShell(trappingHangup: Bool, marker: String) throws -> PTYProcess {
        let trap = trappingHangup ? "trap \"\" HUP; " : ""
        let script = "/bin/sh -c '\(trap)exec /usr/bin/tail -f \"$JETLINE_TEST_MARKER\"'; true"
        let process = PTYProcess(
            executable: ShellScriptLauncher.shell,
            args: ShellScriptLauncher.args(for: script),
            cwd: NSTemporaryDirectory(),
            env: Subprocess.inheritedEnvironment(overrides: [
                "TERM": "xterm-256color",
                "JETLINE_TEST_MARKER": marker
            ]),
            output: { _ in },
            exit: { _ in }
        )
        try process.start()
        return process
    }

    private static func jobProcesses(matching marker: String) -> [JobProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // -ww: without it ps truncates the command column to the terminal
        // width, which would hide a marker sitting at the end of a long
        // temp path and read the leaked process as gone.
        task.arguments = ["-e", "-ww", "-o", "pid,pgid,command"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [] }
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        task.waitUntilExit()

        return output.split(separator: "\n").compactMap { line in
            guard line.contains(marker), line.contains("tail -f") else { return nil }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = fields.first.flatMap({ pid_t($0) }),
                  fields.count > 1, let group = pid_t(fields[1]) else { return nil }
            return JobProcess(pid: pid, group: group)
        }
    }

    private func waitForJob(
        _ marker: String,
        toExist: Bool,
        timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.jobProcesses(matching: marker).isEmpty != toExist { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return Self.jobProcesses(matching: marker).isEmpty != toExist
    }

    private static func forceKill(matching marker: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", marker]
        try? task.run()
        task.waitUntilExit()
    }
}
