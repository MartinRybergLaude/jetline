import Foundation

/// Snapshots of a worktree taken around each chat turn, stored as commits
/// under `refs/jetline/checkpoints/<thread>/…`. They give every turn an exact
/// diff of what the agent changed and make "revert to before this message"
/// possible.
///
/// Snapshots never touch the user's index, branch or stash: the tree is
/// built in a throwaway index (`GIT_INDEX_FILE`) seeded from HEAD, so staged
/// work stays staged and nothing shows up in `git status`. Untracked files
/// are included; ignored ones aren't.
enum Checkpointer {
    static let refRoot = "refs/jetline/checkpoints"

    struct Stat: Codable, Sendable, Equatable {
        var files: Int
        var additions: Int
        var deletions: Int

        static let zero = Stat(files: 0, additions: 0, deletions: 0)
        var isEmpty: Bool { files == 0 }
    }

    static func ref(thread: String, turn: String, phase: String) -> String {
        "\(refRoot)/\(thread)/\(turn)-\(phase)"
    }

    /// Config for every command that touches the temp index: fsmonitor
    /// answers for the real index and would make `git add` skip files.
    private static let indexConfig = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false"]

    /// Commit the worktree's current state and point `ref` at it. Returns
    /// the commit id, or nil when the directory isn't a git worktree.
    static func capture(worktree: String, ref: String?) async -> String? {
        let index = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetline-checkpoint-\(UUID().uuidString).index").path
        defer { try? FileManager.default.removeItem(atPath: index) }
        let env = [
            "GIT_INDEX_FILE": index,
            "GIT_AUTHOR_NAME": "Jetline", "GIT_AUTHOR_EMAIL": "checkpoints@jetline.local",
            "GIT_COMMITTER_NAME": "Jetline", "GIT_COMMITTER_EMAIL": "checkpoints@jetline.local"
        ]
        do {
            let head = (try? await GitRunner.runChecked(["rev-parse", "--verify", "-q", "HEAD"], cwd: worktree))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nonBlank
            if let head {
                if await !seedFromRealIndex(worktree: worktree, tempIndex: index, env: env) {
                    try? FileManager.default.removeItem(atPath: index)
                    try await GitRunner.runChecked(indexConfig + ["read-tree", head], cwd: worktree, env: env)
                }
            }
            try await stageAll(worktree: worktree, env: env)
            let tree = try await GitRunner.runChecked(indexConfig + ["write-tree"], cwd: worktree, env: env)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var commitArgs = ["commit-tree", tree, "-m", "Jetline checkpoint"]
            if let head { commitArgs += ["-p", head] }
            let commit = try await GitRunner.runChecked(commitArgs, cwd: worktree, env: env)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let ref {
                try await GitRunner.runChecked(["update-ref", ref, commit], cwd: worktree)
            }
            return commit
        } catch {
            return nil
        }
    }

    /// Start the temp index from a copy of the real one so `git add -A` can
    /// trust its stat cache instead of re-hashing every file in the repo.
    /// `read-tree --reset HEAD` then drops staged content while keeping
    /// stat data for entries that match HEAD. (T3 Code does the same.)
    ///
    /// Returns false when the copy can't be trusted — sparse checkouts and
    /// entries flagged assume-unchanged or skip-worktree would make the
    /// snapshot silently miss files — and the caller rebuilds from HEAD.
    private static func seedFromRealIndex(worktree: String, tempIndex: String, env: [String: String]) async -> Bool {
        guard let realIndex = try? await GitRunner.runChecked(
            ["rev-parse", "--path-format=absolute", "--git-path", "index"], cwd: worktree
        ).trimmingCharacters(in: .whitespacesAndNewlines),
            let attributes = try? FileManager.default.attributesOfItem(atPath: realIndex),
            let mtime = attributes[.modificationDate] as? Date else { return false }
        let sparse = (try? await GitRunner.runChecked(["config", "--bool", "core.sparseCheckout"], cwd: worktree))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard sparse != "true" else { return false }
        do {
            try FileManager.default.copyItem(atPath: realIndex, toPath: tempIndex)
            try await GitRunner.runChecked(indexConfig + ["read-tree", "--reset", "HEAD"], cwd: worktree, env: env)
            // Keep git's racy-clean check honest: the copy must not look
            // newer than the files it describes.
            try FileManager.default.setAttributes(
                [.modificationDate: mtime.addingTimeInterval(-1)], ofItemAtPath: tempIndex
            )
            let listing = try await GitRunner.runChecked(indexConfig + ["ls-files", "-v", "-z"], cwd: worktree, env: env)
            let flagged = listing.split(separator: "\0").contains { entry in
                guard let tag = entry.first else { return false }
                return tag.isLowercase || tag == "S"
            }
            return !flagged
        } catch {
            return false
        }
    }

    /// `git add -A`, retrying with nested repositories that have no commit
    /// yet excluded — git refuses to stage those at all, which would
    /// otherwise lose the whole checkpoint.
    private static func stageAll(worktree: String, env: [String: String]) async throws {
        let add = indexConfig + ["add", "-A", "--", "."]
        let first = try await GitRunner.run(add, cwd: worktree, env: env)
        guard !first.success else { return }
        let untracked = (try? await GitRunner.runChecked(
            ["ls-files", "--others", "--exclude-standard", "-z", "--", "."], cwd: worktree
        )) ?? ""
        let root = URL(fileURLWithPath: worktree)
        var exclusions: [String] = []
        for entry in untracked.split(separator: "\0").map(String.init) where entry.hasSuffix("/") {
            let nested = root.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path) else { continue }
            let head = try? await GitRunner.run(["rev-parse", "--verify", "-q", "HEAD"], cwd: nested.path)
            if head?.success != true { exclusions.append(":(exclude,literal)\(entry)") }
            if exclusions.count > 200 { break }
        }
        guard !exclusions.isEmpty else {
            throw GitRunner.GitError.nonZeroExit(args: add, status: first.status, stderr: first.stderr)
        }
        try await GitRunner.runChecked(add + exclusions, cwd: worktree, env: env)
    }

    static func stat(worktree: String, from: String, to: String) async -> Stat? {
        guard let out = try? await GitRunner.runChecked(
            ["diff", "--numstat", "--no-renames", "--no-textconv", from, to], cwd: worktree
        ) else { return nil }
        var stat = Stat.zero
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            stat.files += 1
            stat.additions += Int(parts[0]) ?? 0
            stat.deletions += Int(parts[1]) ?? 0
        }
        return stat
    }

    /// Per-file diff between two checkpoints.
    static func diff(worktree: String, from: String, to: String) async -> [FileDiff] {
        async let patchOutput = try? GitRunner.runChecked(
            // Explicit prefixes and no textconv: the user's `diff.noprefix`
            // or textconv drivers would otherwise change what we parse.
            ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
             "--src-prefix=a/", "--dst-prefix=b/", from, to],
            cwd: worktree
        )
        async let statusOutput = try? GitRunner.runChecked(
            ["diff", "--name-status", "--no-renames", from, to], cwd: worktree
        )
        guard let patch = await patchOutput else { return [] }
        var statuses: [String: FileDiff.Status] = [:]
        for line in (await statusOutput ?? "").split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            statuses[String(parts[1])] = FileDiff.Status(rawValue: String(parts[0].prefix(1))) ?? .modified
        }
        return PatchParser.parse(patch).map { file in
            let lines = file.hunks.flatMap(\.lines)
            return FileDiff(
                path: file.path,
                status: statuses[file.path] ?? .modified,
                additions: lines.filter { $0.kind == .addition }.count,
                deletions: lines.filter { $0.kind == .deletion }.count,
                hunks: file.hunks,
                isBinary: file.isBinary
            )
        }
    }

    /// Put every file back the way it was at `commit`. Files created since
    /// are deleted; the index isn't touched, so anything the user had
    /// staged stays staged.
    static func restore(worktree: String, to commit: String) async throws {
        guard let current = await capture(worktree: worktree, ref: nil) else {
            throw AgentError.requestFailed("Couldn't snapshot the worktree before reverting.")
        }
        let changes = try await GitRunner.runChecked(
            ["diff", "--name-status", "--no-renames", "-z", commit, current], cwd: worktree
        )
        // -z output: status NUL path NUL status NUL path NUL …
        let fields = changes.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var restore: [String] = []
        var remove: [String] = []
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index]
            let path = fields[index + 1]
            index += 2
            if status.hasPrefix("A") {
                remove.append(path)
            } else {
                restore.append(path)
            }
        }
        let root = URL(fileURLWithPath: worktree)
        for path in remove {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
        }
        // Batches keep the argument list under ARG_MAX on big reverts.
        for batch in stride(from: 0, to: restore.count, by: 200).map({ Array(restore[$0..<min($0 + 200, restore.count)]) }) {
            // Literal pathspecs: a file named `[id].tsx` is a glob otherwise.
            try await GitRunner.runChecked(
                ["--literal-pathspecs", "restore", "--source", commit, "--worktree", "--"] + batch, cwd: worktree
            )
        }
    }

    /// Drop every checkpoint ref of `thread`.
    static func deleteRefs(worktree: String, thread: String) async {
        guard let refs = try? await GitRunner.runChecked(
            ["for-each-ref", "--format=%(refname)", "\(refRoot)/\(thread)/"], cwd: worktree
        ) else { return }
        for ref in refs.split(separator: "\n") {
            _ = try? await GitRunner.run(["update-ref", "-d", String(ref)], cwd: worktree)
        }
    }
}
