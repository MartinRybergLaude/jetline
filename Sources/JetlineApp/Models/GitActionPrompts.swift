import Foundation

/// Default prompts for each `GitAction` plus a renderer that substitutes
/// workspace/PR placeholders. The fallback chain is:
///   Repository.<actionPrompt> → AppSettings.<actionPrompt> → defaults[action]
///
/// Templates use `{branch}`, `{baseBranch}`, `{prNumber}`, `{prTitle}`,
/// `{prUrl}`, `{ciFailures}`, `{worktreePath}`. Missing values render as
/// empty strings so half-populated prompts don't leak `{prNumber}` placeholders.
enum GitActionPrompts {
    static let defaults: [GitAction: String] = [
        .commit: """
        Commit the uncommitted changes in this workspace. Branch: {branch}.
        Run `git status` and `git diff` first, write a clear conventional commit \
        message that explains the *why*, then `git commit`. Don't push.
        """,
        .createPR: """
        Push branch {branch} and open a pull request against {baseBranch} using \
        `gh pr create`. Pick a clear title and a brief summary based on the diff. \
        Include a "Test plan" section if relevant.
        """,
        .pullUpdates: """
        The remote branch origin/{branch} has commits the local worktree \
        doesn't. Run `git pull --rebase` to bring the local branch up to \
        date, resolving any conflicts with judgement (don't blindly accept \
        either side).
        """,
        .rebaseOnMain: """
        Rebase {branch} onto the latest {baseBranch}. Fetch first, then \
        `git rebase origin/{baseBranch}`, resolving any conflicts with \
        judgement (don't blindly accept either side). Force-push with \
        `--force-with-lease` when the rebase is clean.
        """,
        .fixCI: """
        PR #{prNumber} ({prUrl}) has failing CI checks: {ciFailures}.
        Inspect the logs (`gh run view --log-failed` or similar), fix the \
        underlying issues, and commit + push the fix.
        """,
        .fixComments: """
        PR #{prNumber} has open comments. Fetch the full conversation with \
        `gh pr view {prNumber} --comments` (and `gh api ...` for inline review \
        threads if you need detail), then address each one — with code changes \
        if it's a request, with a reply if it's a question. Commit and push \
        any code fixes.
        """,
        .review: """
        Review the diff in this workspace against {baseBranch}. Read the changes \
        carefully and look for bugs, design problems, missed edge cases, and \
        inconsistencies with the surrounding codebase. Report findings as a \
        prioritized list (critical → nit). Don't change any code.
        """
    ]

    /// Resolve the user-facing prompt template through the override chain.
    /// `mergePR` returns `nil` because it doesn't spawn an agent.
    static func template(
        for action: GitAction,
        repository: Repository?,
        settings: AppSettings
    ) -> String? {
        if action == .mergePR { return nil }
        if let perRepo = repository?.prompt(for: action)?.nonBlank { return perRepo }
        if let global = settings.prompt(for: action)?.nonBlank { return global }
        return defaults[action]
    }

    static func render(
        _ template: String,
        workspace: Workspace,
        pr: PullRequest?,
        checks: [CheckRun]
    ) -> String {
        let failingNames = checks
            .filter { $0.bucket == .fail }
            .map { run -> String in
                if let workflow = run.workflow, !workflow.isEmpty { return "\(workflow) / \(run.name)" }
                return run.name
            }
            .joined(separator: ", ")

        var out = template
        out = out.replacingOccurrences(of: "{branch}", with: workspace.branchName)
        out = out.replacingOccurrences(of: "{baseBranch}", with: workspace.baseBranch)
        out = out.replacingOccurrences(of: "{worktreePath}", with: workspace.worktreePath)
        out = out.replacingOccurrences(of: "{prNumber}", with: pr.map { String($0.number) } ?? "")
        out = out.replacingOccurrences(of: "{prTitle}", with: pr?.title ?? "")
        out = out.replacingOccurrences(of: "{prUrl}", with: pr?.url ?? "")
        out = out.replacingOccurrences(of: "{ciFailures}", with: failingNames.isEmpty ? "(see PR)" : failingNames)
        return out
    }
}
