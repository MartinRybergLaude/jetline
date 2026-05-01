import Foundation

/// Thin wrapper around `git` subprocess invocation. Async; never blocks the main actor.
enum GitRunner {
    typealias Result = Subprocess.Result

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
        let result = await Subprocess.run(
            executable: "/usr/bin/env",
            args: ["git"] + args,
            cwd: cwd,
            env: env
        )
        if result.status == -1 {
            throw GitError.nonZeroExit(args: args, status: -1, stderr: result.stderr)
        }
        return result
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
}
