import Foundation

/// Keeps the repository's local default branch tracking `<remote>/<base>`
/// without ever blowing away local commits. Diff-against-base and new-
/// worktree creation both resolve through the *local* ref, so without
/// this helper the local `main` drifts behind origin and every derived
/// view (diff stats, fresh worktrees) starts wrong.
enum BaseBranchSync {
    /// Best-effort fast-forward of `<baseBranch>` to `<remote>/<baseBranch>`.
    /// Idempotent. Returns the new SHA when the ref moved, `nil` otherwise
    /// — callers use that to drive downstream recomputation (diff stats).
    ///
    /// Two paths, picked by where the branch is currently checked out:
    /// - **Detached or nowhere checked out:** `git update-ref` moves the
    ///   ref directly with a CAS guard. No working-tree touch.
    /// - **Checked out in one or more worktrees** (typically the bare
    ///   repo): `git merge --ff-only` inside each so HEAD stays in sync
    ///   with the branch tip.
    ///
    /// No-ops:
    /// - `<remote>/<baseBranch>` doesn't exist (offline / brand-new repo).
    /// - Local already matches remote.
    /// - Local has commits the upstream doesn't (would not be a FF —
    ///   leave the divergence for the user to resolve).
    @discardableResult
    static func fastForward(
        repoPath: String,
        remote: String,
        baseBranch: String
    ) async -> String? {
        let remoteRef = "\(remote)/\(baseBranch)"
        let localRef = "refs/heads/\(baseBranch)"

        async let upstream = BranchPositionOps.resolveRef(remoteRef, cwd: repoPath)
        async let local = BranchPositionOps.resolveRef(localRef, cwd: repoPath)
        let (upstreamSHA, localSHA) = await (upstream, local)

        guard let upstreamSHA else { return nil }
        if localSHA == upstreamSHA { return nil }

        // FF guard: refuse to fast-forward over local commits the user
        // made on the default branch directly. Rare, but the failure
        // mode (silent commit loss) is bad enough to warrant the check.
        if let localSHA {
            let result = try? await GitRunner.run(
                ["merge-base", "--is-ancestor", localSHA, upstreamSHA],
                cwd: repoPath
            )
            guard result?.success == true else { return nil }
        }

        let consumers = (try? await WorktreeOps.worktreesUsing(
            branch: baseBranch,
            repoPath: repoPath
        )) ?? []
        if consumers.isEmpty {
            // Pure ref move. CAS guard catches another process moving the
            // ref between our read and the write.
            var args = ["update-ref", localRef, upstreamSHA]
            if let localSHA { args.append(localSHA) }
            let result = try? await GitRunner.run(args, cwd: repoPath)
            return result?.success == true ? upstreamSHA : nil
        }

        var movedSomewhere = false
        for path in consumers {
            let result = try? await GitRunner.run(
                ["merge", "--ff-only", remoteRef], cwd: path
            )
            if result?.success == true { movedSomewhere = true }
        }
        return movedSomewhere ? upstreamSHA : nil
    }
}
