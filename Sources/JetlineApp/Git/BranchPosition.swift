import Foundation

/// Local ahead/behind state for a workspace's branch. Drives the
/// `Pull updates` and `Rebase on main` actions in the toolbar git menu.
///
/// Computed locally (after a `git fetch`) so it's available before a PR
/// exists, and accurate even when GitHub's `mergeStateStatus` doesn't fire
/// `BEHIND` (which only happens under specific branch-protection rules).
struct BranchPosition: Equatable {
    /// Commits on `origin/<branch>` that aren't on the local branch.
    var behindRemote: Int = 0
    /// Local commits not on `origin/<branch>`.
    var aheadOfRemote: Int = 0
    /// Commits on `origin/<baseBranch>` that aren't on the local branch.
    var behindBase: Int = 0
    /// Whether `origin/<branch>` exists. False for branches that have never
    /// been pushed — in that case `Pull updates` stays disabled regardless
    /// of the counts.
    var remoteTrackingExists: Bool = false

    /// `Pull updates` is meaningful when the remote has commits we don't,
    /// even if we also have local commits (a rebase reconciles both).
    var remoteHasNewCommits: Bool { remoteTrackingExists && behindRemote > 0 }
    /// `Rebase on main` is meaningful when the base has commits we don't.
    var isBehindBase: Bool { behindBase > 0 }
}

enum BranchPositionOps {
    /// Best-effort `git fetch` of the relevant refs. Failure is swallowed
    /// so a flaky network leaves the previous counts in place rather than
    /// blocking the poll loop.
    static func fetch(repoPath: String, remote: String) async {
        _ = try? await GitRunner.run(["fetch", "--quiet", remote], cwd: repoPath)
    }

    /// Compare `HEAD` against the candidate refs and produce a
    /// `BranchPosition`. Missing refs (e.g. unpushed branch) collapse to
    /// zero counts rather than throwing.
    static func compute(
        worktreePath: String,
        branchName: String,
        baseBranch: String,
        remote: String
    ) async -> BranchPosition {
        var pos = BranchPosition()

        let remoteBranch = "\(remote)/\(branchName)"
        if await refExists(remoteBranch, cwd: worktreePath),
           let (ahead, behind) = await leftRightCount(
               cwd: worktreePath,
               left: "HEAD",
               right: remoteBranch
           ) {
            pos.remoteTrackingExists = true
            pos.aheadOfRemote = ahead
            pos.behindRemote = behind
        }

        // Prefer the remote-tracking form of the base ref since `git fetch`
        // updates it. Fall back to the local form for repos with no remote
        // base (rare, but DiffComputer also accepts whatever resolves).
        let baseLocalName = stripRemotePrefix(baseBranch, remote: remote)
        let remoteBase = "\(remote)/\(baseLocalName)"
        let baseRef: String?
        if await refExists(remoteBase, cwd: worktreePath) {
            baseRef = remoteBase
        } else if await refExists(baseBranch, cwd: worktreePath) {
            baseRef = baseBranch
        } else {
            baseRef = nil
        }
        if let baseRef,
           let (_, behind) = await leftRightCount(
               cwd: worktreePath,
               left: "HEAD",
               right: baseRef
           ) {
            pos.behindBase = behind
        }
        return pos
    }

    private static func stripRemotePrefix(_ ref: String, remote: String) -> String {
        let prefix = "\(remote)/"
        return ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : ref
    }

    /// Resolve `ref` to its SHA, or `nil` if it doesn't exist or git
    /// errors out. Shared with `BaseBranchSync` — both want the same
    /// `git rev-parse --verify --quiet` semantics.
    static func resolveRef(_ ref: String, cwd: String) async -> String? {
        let result = try? await GitRunner.run(
            ["rev-parse", "--verify", "--quiet", ref],
            cwd: cwd
        )
        guard result?.success == true,
              let sha = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
              !sha.isEmpty else { return nil }
        return sha
    }

    private static func refExists(_ ref: String, cwd: String) async -> Bool {
        await resolveRef(ref, cwd: cwd) != nil
    }

    private static func leftRightCount(
        cwd: String,
        left: String,
        right: String
    ) async -> (Int, Int)? {
        guard let raw = try? await GitRunner.runChecked(
            ["rev-list", "--left-right", "--count", "\(left)...\(right)"],
            cwd: cwd
        ) else { return nil }
        let parts = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
        guard parts.count == 2,
              let l = Int(parts[0]),
              let r = Int(parts[1]) else { return nil }
        return (l, r)
    }
}
