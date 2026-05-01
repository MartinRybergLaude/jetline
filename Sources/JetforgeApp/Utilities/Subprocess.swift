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

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment

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

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
