import Foundation

/// Worktree lifecycle: create branch + worktree, remove worktree, detect repo info.
enum WorktreeOps {
    enum ImportError: LocalizedError {
        case branchInUse(branch: String, byPath: String)

        var errorDescription: String? {
            switch self {
            case let .branchInUse(branch, path):
                return "Branch \(branch) is already checked out at \(path)."
            }
        }
    }

    /// Detect default branch (main, master, etc.) of a repo.
    static func defaultBranch(at repoPath: String) async throws -> String {
        if let symbolic = try? await GitRunner.runChecked(
            ["symbolic-ref", "refs/remotes/origin/HEAD"],
            cwd: repoPath
        ) {
            // Output like "refs/remotes/origin/main"
            let trimmed = symbolic.trimmingCharacters(in: .whitespacesAndNewlines)
            if let last = trimmed.split(separator: "/").last {
                return String(last)
            }
        }
        for candidate in ["main", "master"] {
            let result = try await GitRunner.run(
                ["rev-parse", "--verify", candidate],
                cwd: repoPath
            )
            if result.success { return candidate }
        }
        return "main"
    }

    /// Detect a friendly repo name (basename of the repo path).
    static func detectName(at path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// True if the path is the top of a git working tree.
    static func isGitRepo(at path: String) async -> Bool {
        let result = try? await GitRunner.run(
            ["rev-parse", "--is-inside-work-tree"],
            cwd: path
        )
        return (result?.success ?? false) &&
            result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Create a new branch (off `baseBranch`) and a worktree for it.
    /// Returns the absolute path of the new worktree.
    static func create(
        repoPath: String,
        worktreeId: String,
        repoId: String,
        branchName: String,
        baseBranch: String
    ) async throws -> String {
        let worktreesRoot = Database.worktreesDirectory
            .appendingPathComponent(repoId, isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)

        let worktreePath = worktreesRoot
            .appendingPathComponent(worktreeId, isDirectory: true)
            .path

        try await GitRunner.runChecked(
            ["worktree", "add", "-b", branchName, worktreePath, baseBranch],
            cwd: repoPath
        )
        return worktreePath
    }

    /// Fetch a single ref from a remote so the local repo has the commits
    /// before we try to materialize them in a worktree.
    static func fetch(repoPath: String, remote: String, ref: String) async throws {
        try await GitRunner.runChecked(["fetch", remote, ref], cwd: repoPath)
    }

    /// Materialize an *existing* remote branch as a new worktree. Creates a
    /// local branch (force-resetting if it already exists) tracking
    /// `remote/branch`, then `git worktree add`s it. Throws
    /// `ImportError.branchInUse` if the branch is already attached to a
    /// different worktree (git would reject the add anyway, but a typed error
    /// gives the UI a chance to surface a useful message).
    static func importExisting(
        repoPath: String,
        worktreeId: String,
        repoId: String,
        branchName: String,
        remote: String
    ) async throws -> String {
        // Drop registry entries whose worktree directories no longer exist —
        // otherwise a previously-deleted worktree would still hold its branch
        // hostage and we'd report a phantom collision.
        _ = try? await GitRunner.run(["worktree", "prune"], cwd: repoPath)

        if let path = try await worktreeUsing(branch: branchName, repoPath: repoPath) {
            throw ImportError.branchInUse(branch: branchName, byPath: path)
        }
        try await fetch(repoPath: repoPath, remote: remote, ref: branchName)

        let worktreesRoot = Database.worktreesDirectory
            .appendingPathComponent(repoId, isDirectory: true)
        try FileManager.default.createDirectory(at: worktreesRoot, withIntermediateDirectories: true)
        let worktreePath = worktreesRoot
            .appendingPathComponent(worktreeId, isDirectory: true)
            .path

        try await GitRunner.runChecked(
            ["worktree", "add", "-B", branchName, worktreePath, "\(remote)/\(branchName)"],
            cwd: repoPath
        )
        return worktreePath
    }

    /// Remote-tracking branches (e.g. `origin/feature`) sorted by most-recent
    /// commit first. The HEAD pseudo-ref is excluded. Empty array on failure.
    static func listRemoteBranches(
        repoPath: String,
        remote: String
    ) async -> [(ref: String, lastCommitAt: Date)] {
        let format = "%(refname:short)\t%(committerdate:iso8601)"
        guard let raw = try? await GitRunner.runChecked(
            ["for-each-ref", "--sort=-committerdate", "refs/remotes/\(remote)", "--format=\(format)"],
            cwd: repoPath
        ) else { return [] }

        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
        return raw
            .split(separator: "\n")
            .compactMap { line -> (String, Date)? in
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let ref = String(parts[0])
                guard !ref.hasSuffix("/HEAD"),
                      let date = parser.date(from: String(parts[1])) else { return nil }
                return (ref, date)
            }
    }

    /// Returns the worktree path that has `branch` checked out, or `nil` if
    /// no worktree owns it. Parses `git worktree list --porcelain`, which
    /// emits stanzas of `worktree`/`HEAD`/`branch` lines separated by blanks.
    private static func worktreeUsing(branch: String, repoPath: String) async throws -> String? {
        let raw = try await GitRunner.runChecked(["worktree", "list", "--porcelain"], cwd: repoPath)
        var path: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                let name = String(line.dropFirst("branch refs/heads/".count))
                if name == branch, let path { return path }
            }
        }
        return nil
    }

    /// Remove a worktree and (optionally) its branch.
    static func remove(repoPath: String, worktreePath: String, branchName: String?, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        try await GitRunner.runChecked(args, cwd: repoPath)

        if let branchName {
            // Best-effort branch deletion — fine if it fails (already gone, etc.)
            _ = try? await GitRunner.run(["branch", "-D", branchName], cwd: repoPath)
        }
    }

    /// All configured git remotes (`git remote`). Empty array if the repo
    /// has no remotes configured.
    static func listRemotes(at repoPath: String) async -> [String] {
        await gitLines(["remote"], cwd: repoPath)
    }

    /// Branch refs suitable for a base-branch picker: local branches plus
    /// remote-tracking branches (e.g. `main`, `origin/main`). Sorted
    /// alphabetically and deduped.
    static func listBaseRefs(at repoPath: String) async -> [String] {
        async let locals = gitLines(["branch", "--format=%(refname:short)"], cwd: repoPath)
        async let remotes = gitLines(["branch", "-r", "--format=%(refname:short)"], cwd: repoPath)
        let combined = (await locals) + (await remotes).filter { !$0.contains("HEAD ->") }
        return Array(Set(combined)).sorted()
    }

    private static func gitLines(_ args: [String], cwd: String) async -> [String] {
        guard let out = try? await GitRunner.runChecked(args, cwd: cwd) else { return [] }
        return out
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Generate a slug-safe branch name from a workspace name.
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = lowered.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let base = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let hasAlphanum = base.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        return hasAlphanum ? base : "workspace"
    }
}
