import Foundation

/// Thin wrapper around `git` subprocess invocation. Async; never blocks the main actor.
enum GitRunner {
    struct Result {
        var stdout: String
        var stderr: String
        var status: Int32
        var success: Bool { status == 0 }
    }

    enum GitError: LocalizedError {
        case nonZeroExit(args: [String], status: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case let .nonZeroExit(args, status, stderr):
                return "git \(args.joined(separator: " ")) failed (\(status)): \(stderr)"
            }
        }
    }

    @discardableResult
    static func run(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String] = [:]
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            try runSync(args, cwd: cwd, env: env)
        }.value
    }

    @discardableResult
    static func runChecked(
        _ args: [String],
        cwd: String? = nil,
        env: [String: String] = [:]
    ) async throws -> String {
        let result = try await run(args, cwd: cwd, env: env)
        guard result.success else {
            throw GitError.nonZeroExit(args: args, status: result.status, stderr: result.stderr)
        }
        return result.stdout
    }

    private static func runSync(_ args: [String], cwd: String?, env: [String: String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args

        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Result(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}
