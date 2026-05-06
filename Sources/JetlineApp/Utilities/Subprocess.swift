import Foundation

/// Shared `Process` plumbing. Captures stdout+stderr, merges env on top of
/// the inherited environment, optionally enforces a timeout. Always returns
/// — spawn failures are reported as `status = -1` with the OS error in
/// stderr so callers can pattern-match without try/catch noise.
enum Subprocess {
    struct Result: Sendable {
        var stdout: String
        var stderr: String
        var status: Int32
        var success: Bool { status == 0 }
    }

    /// Returns the current process environment with `overrides` layered on
    /// top. Used everywhere we spawn — keeps inherited PATH/HOME/etc.
    static func inheritedEnvironment(overrides: [String: String]) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in overrides { merged[k] = v }
        return merged
    }

    static func run(
        executable: String,
        args: [String],
        cwd: String? = nil,
        env: [String: String] = [:],
        closeStdin: Bool = false,
        timeout: TimeInterval? = nil
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            runSync(
                executable: executable,
                args: args,
                cwd: cwd,
                env: env,
                closeStdin: closeStdin,
                timeout: timeout
            )
        }.value
    }

    private static func runSync(
        executable: String,
        args: [String],
        cwd: String?,
        env: [String: String],
        closeStdin: Bool,
        timeout: TimeInterval?
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }

        process.environment = Subprocess.inheritedEnvironment(overrides: env)

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if closeStdin { process.standardInput = FileHandle.nullDevice }

        do {
            try process.run()
        } catch {
            return Result(stdout: "", stderr: "spawn failed: \(error)", status: -1)
        }

        // Drain pipes concurrently — without this, output larger than the
        // pipe buffer (~16KB on macOS) blocks the child on write while the
        // parent blocks on waitUntilExit.
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let readQ = DispatchQueue.global(qos: .userInitiated)

        group.enter()
        readQ.async {
            outData = outHandle.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        readQ.async {
            errData = errHandle.readDataToEndOfFile()
            group.leave()
        }

        if let timeout {
            let killer = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            process.waitUntilExit()
            killer.cancel()
        } else {
            process.waitUntilExit()
        }

        // Bounded drain. The process is dead, so anything still in the pipe
        // is whatever the kernel buffered before the write end closed —
        // which usually drains in microseconds. If readers are still
        // pending after a grace period, a forked-and-detached descendant
        // (git's `fsmonitor--daemon`, SSH `ControlMaster`, a credential
        // helper) inherited fd 1/2 and is keeping the write ends open.
        // We don't want that descendant's output, but `readDataToEndOfFile`
        // will block until *every* writer closes — pinning a Task thread
        // forever, which compounds across calls until new agent tabs and
        // git ops both wedge. Force-close the read ends so the readers
        // see EBADF and unwind.
        if group.wait(timeout: .now() + .milliseconds(250)) == .timedOut {
            try? outHandle.close()
            try? errHandle.close()
            group.wait()
        }

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
