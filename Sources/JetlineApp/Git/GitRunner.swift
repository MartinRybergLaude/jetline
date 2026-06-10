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
        // Never take optional locks. Background reads (`status`, `diff`)
        // otherwise grab `index.lock` to write back a refreshed stat cache,
        // and since the diff watcher fires on every worktree/git-dir change,
        // they race agent-run `git commit`/`git add` in the same worktree —
        // git doesn't retry the index lock, so the loser dies with
        // "Unable to create index.lock: File exists". Mandatory locks
        // (commit, rebase, stash) are unaffected by this knob.
        var env = env
        if env["GIT_OPTIONAL_LOCKS"] == nil { env["GIT_OPTIONAL_LOCKS"] = "0" }
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
