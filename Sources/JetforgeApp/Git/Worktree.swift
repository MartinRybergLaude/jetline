import Foundation

/// Worktree lifecycle: create branch + worktree, remove worktree, detect repo info.
enum WorktreeOps {
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
        guard let out = try? await GitRunner.runChecked(["remote"], cwd: repoPath) else {
            return []
        }
        return out
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Branch refs suitable for a base-branch picker: local branches plus
    /// remote-tracking branches (e.g. `main`, `origin/main`). Sorted
    /// alphabetically with remote-tracking refs after locals.
    static func listBaseRefs(at repoPath: String) async -> [String] {
        async let locals = branches(at: repoPath, args: ["branch", "--format=%(refname:short)"])
        async let remotes = branches(at: repoPath, args: ["branch", "-r", "--format=%(refname:short)"])
        let combined = (await locals) + (await remotes).filter { !$0.contains("HEAD ->") }
        return Array(NSOrderedSet(array: combined.sorted())) as? [String] ?? combined.sorted()
    }

    private static func branches(at repoPath: String, args: [String]) async -> [String] {
        guard let out = try? await GitRunner.runChecked(args, cwd: repoPath) else { return [] }
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
