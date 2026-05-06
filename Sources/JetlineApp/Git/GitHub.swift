import Foundation

/// Models + thin wrapper around the `gh` CLI. We shell out rather than call
/// the GitHub REST API directly so we inherit the user's existing `gh auth`
/// credentials, host config, and SSO state.

struct PullRequest: Codable, Sendable, Hashable {
    struct Author: Codable, Sendable, Hashable {
        var login: String
    }
    var number: Int
    var title: String
    var url: String
    var state: String
    var isDraft: Bool
    var headRefName: String
    var baseRefName: String
    var author: Author
    /// `MERGEABLE` / `CONFLICTING` / `UNKNOWN`.
    var mergeable: String?
    /// `BEHIND` / `BLOCKED` / `CLEAN` / `DIRTY` / `HAS_HOOKS` / `UNKNOWN` /
    /// `UNSTABLE`. Drives the "Pull updates" / "Merge PR" branches of the
    /// action-bar state machine.
    var mergeStateStatus: String?
    /// Number of unresolved inline review threads.
    var unresolvedThreadCount: Int = 0
    /// Number of top-level issue comments on the PR. Distinct from review
    /// threads — a general PR comment doesn't create a thread.
    var issueCommentCount: Int = 0
    /// `APPROVED` / `CHANGES_REQUESTED` / `REVIEW_REQUIRED`, or `nil` when
    /// the repo doesn't require review (no branch protection configured).
    /// Drives the merge gate so the toolbar matches GitHub's UI.
    var reviewDecision: String?

    var hasOpenComments: Bool {
        unresolvedThreadCount > 0 || issueCommentCount > 0
    }

    init(
        number: Int,
        title: String,
        url: String,
        state: String,
        isDraft: Bool,
        headRefName: String,
        baseRefName: String,
        author: Author,
        mergeable: String? = nil,
        mergeStateStatus: String? = nil,
        unresolvedThreadCount: Int = 0,
        issueCommentCount: Int = 0,
        reviewDecision: String? = nil
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.author = author
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.unresolvedThreadCount = unresolvedThreadCount
        self.issueCommentCount = issueCommentCount
        self.reviewDecision = reviewDecision
    }

    enum CodingKeys: String, CodingKey {
        case number, title, url, state, isDraft, headRefName, baseRefName, author
        case mergeable, mergeStateStatus, unresolvedThreadCount, issueCommentCount
        case reviewDecision
    }

    /// Custom decode so PR snapshots persisted before the comment-tracking
    /// fields existed still load cleanly. Synthesised `init(from:)` calls
    /// `decode` for non-Optional fields and ignores struct-level default
    /// values, so old JSON without `unresolvedThreadCount` / `issueCommentCount`
    /// would otherwise throw and get silently dropped by `PRSnapshots.decode`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        state = try c.decode(String.self, forKey: .state)
        isDraft = try c.decode(Bool.self, forKey: .isDraft)
        headRefName = try c.decode(String.self, forKey: .headRefName)
        baseRefName = try c.decode(String.self, forKey: .baseRefName)
        author = try c.decode(Author.self, forKey: .author)
        mergeable = try c.decodeIfPresent(String.self, forKey: .mergeable)
        mergeStateStatus = try c.decodeIfPresent(String.self, forKey: .mergeStateStatus)
        unresolvedThreadCount = try c.decodeIfPresent(Int.self, forKey: .unresolvedThreadCount) ?? 0
        issueCommentCount = try c.decodeIfPresent(Int.self, forKey: .issueCommentCount) ?? 0
        reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
    }
}

/// Discriminated string enums whose serialized form matches the GitHub API's
/// SCREAMING_SNAKE constants. `gh pr checks` (REST) and `gh api graphql` both
/// emit these forms, so we can round-trip JSON without a separate mapping.
enum CheckStatus: String, Codable, Sendable, Hashable {
    case queued = "QUEUED"
    case inProgress = "IN_PROGRESS"
    case completed = "COMPLETED"
    case waiting = "WAITING"
    case requested = "REQUESTED"
    case pending = "PENDING"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.uppercased() ?? ""
        self = CheckStatus(rawValue: raw) ?? .unknown
    }
}

enum CheckConclusion: String, Codable, Sendable, Hashable {
    case success = "SUCCESS"
    case failure = "FAILURE"
    case neutral = "NEUTRAL"
    case cancelled = "CANCELLED"
    case skipped = "SKIPPED"
    case timedOut = "TIMED_OUT"
    case actionRequired = "ACTION_REQUIRED"
    case stale = "STALE"
    case unknown = "UNKNOWN"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.uppercased() ?? ""
        self = CheckConclusion(rawValue: raw) ?? .unknown
    }
}

/// Coarse status used for grouping/coloring. `gh pr checks` emits this in
/// lowercase; we keep that on the wire for backwards-compat with persisted
/// rows but synthesize it ourselves from `(status, conclusion)` when reading
/// GraphQL responses (which don't include a bucket field).
enum CheckBucket: String, Codable, Sendable, Hashable {
    case pass = "pass"
    case fail = "fail"
    case pending = "pending"
    case skipping = "skipping"
    case cancel = "cancel"
    case unknown = "unknown"

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self))?.lowercased() ?? ""
        self = CheckBucket(rawValue: raw) ?? .unknown
    }

    /// Best-effort bucket derivation when only `(status, conclusion)` is
    /// available — used for GraphQL `CheckRun` contexts.
    static func derive(status: CheckStatus, conclusion: CheckConclusion) -> CheckBucket {
        switch status {
        case .queued, .inProgress, .pending, .waiting, .requested:
            return .pending
        case .completed:
            switch conclusion {
            case .success, .neutral:           return .pass
            case .failure, .timedOut, .actionRequired: return .fail
            case .cancelled:                   return .cancel
            case .skipped, .stale:             return .skipping
            case .unknown:                     return .unknown
            }
        case .unknown:
            return .unknown
        }
    }
}

struct CheckRun: Codable, Sendable, Hashable, Identifiable {
    var name: String
    var status: CheckStatus
    var conclusion: CheckConclusion
    var bucket: CheckBucket
    var link: String?
    var workflow: String?
    var startedAt: String?
    var completedAt: String?

    /// gh `pr checks` doesn't expose a stable id, so combine workflow+name.
    /// Duplicates collapse, which is acceptable for a status list.
    var id: String { "\(workflow ?? "")::\(name)" }

    var isActive: Bool {
        switch status {
        case .queued, .inProgress, .pending, .waiting, .requested:
            return true
        case .completed, .unknown:
            return bucket == .pending
        }
    }

    init(
        name: String,
        status: CheckStatus,
        conclusion: CheckConclusion,
        bucket: CheckBucket,
        link: String? = nil,
        workflow: String? = nil,
        startedAt: String? = nil,
        completedAt: String? = nil
    ) {
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.bucket = bucket
        self.link = link
        self.workflow = workflow
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, status, conclusion, bucket, link, workflow, startedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        status = (try? c.decode(CheckStatus.self, forKey: .status)) ?? .unknown
        conclusion = (try? c.decode(CheckConclusion.self, forKey: .conclusion)) ?? .unknown
        bucket = (try? c.decode(CheckBucket.self, forKey: .bucket)) ?? .unknown
        link = try c.decodeIfPresent(String.self, forKey: .link)
        workflow = try c.decodeIfPresent(String.self, forKey: .workflow)
        startedAt = try c.decodeIfPresent(String.self, forKey: .startedAt)
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt)
    }
}

/// Slim PR row used by the import picker. Distinct from `PullRequest`
/// because the picker needs `headRepositoryOwner` (for fork detection) and
/// `updatedAt` (for the row caption) that the per-branch tracker query
/// doesn't fetch — and conversely doesn't need review-thread/comment counts.
struct PRSummary: Sendable, Hashable, Identifiable {
    let number: Int
    let title: String
    let authorLogin: String
    let headRefName: String
    let headRepositoryOwner: String
    let baseRefName: String
    let isDraft: Bool
    let updatedAt: Date
    /// Coarse rollup of all checks on the head commit. `nil` when no checks
    /// have run.
    let checkBucket: CheckBucket?

    var id: Int { number }

    func isFork(of repo: RepoIdentifier) -> Bool {
        headRepositoryOwner.caseInsensitiveCompare(repo.owner) != .orderedSame
    }
}

enum PRSnapshot: Equatable, Sendable {
    case loading
    case error(String)
    case absent
    case loaded(PullRequest, [CheckRun])
}

/// Owner/name pair identifying a GitHub repository, plus the merge methods
/// the repo's settings allow. Cached per-repo by `PRTracker` and surfaced
/// to the UI via `AppState.repoMetadataByRepo` so the merge confirmation
/// dialog can show only the buttons that will actually work.
struct RepoIdentifier: Sendable, Hashable {
    let owner: String
    let name: String
    let allowedMergeMethods: Set<MergeMethod>
}

/// One of the three merge strategies GitHub offers. The repo admin picks
/// which subset is enabled in Settings → General → Pull Requests.
enum MergeMethod: String, CaseIterable, Hashable, Sendable {
    case merge
    case squash
    case rebase

    /// Matches GitHub's web UI labels.
    var displayName: String {
        switch self {
        case .merge:  return "Create a merge commit"
        case .squash: return "Squash and merge"
        case .rebase: return "Rebase and merge"
        }
    }

    /// `gh pr merge` flag for this method.
    var ghFlag: String {
        switch self {
        case .merge:  return "--merge"
        case .squash: return "--squash"
        case .rebase: return "--rebase"
        }
    }

    /// Display order matches GitHub's merge dropdown.
    static let displayOrder: [MergeMethod] = [.merge, .squash, .rebase]
}

enum GitHubRunner {
    enum Error: LocalizedError {
        case ghMissing
        case authRequired
        case notOnGitHub
        case other(String)

        var errorDescription: String? {
            switch self {
            case .ghMissing: return "gh CLI not found on PATH. Install via `brew install gh`."
            case .authRequired: return "gh not authenticated. Run `gh auth login` in a terminal."
            case .notOnGitHub: return "Repository has no GitHub remote."
            case let .other(msg): return msg
            }
        }
    }

    /// Resolve the repo's GitHub owner/name. `gh` infers the remote from the
    /// working directory, so any path inside the repo works. Returns `nil`
    /// when the repo has no GitHub remote (we don't want to error in that
    /// case — it's a normal, recurring state).
    static func repoIdentifier(cwd: String) async throws -> RepoIdentifier? {
        do {
            let stdout = try await runGH(
                ["repo", "view", "--json", "owner,name,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed"],
                cwd: cwd
            )
            struct Response: Decodable {
                struct Owner: Decodable { let login: String }
                let owner: Owner
                let name: String
                let mergeCommitAllowed: Bool?
                let squashMergeAllowed: Bool?
                let rebaseMergeAllowed: Bool?
            }
            let parsed = try JSONDecoder().decode(Response.self, from: Data(stdout.utf8))
            var methods: Set<MergeMethod> = []
            if parsed.mergeCommitAllowed == true  { methods.insert(.merge) }
            if parsed.squashMergeAllowed == true  { methods.insert(.squash) }
            if parsed.rebaseMergeAllowed == true  { methods.insert(.rebase) }
            return RepoIdentifier(
                owner: parsed.owner.login,
                name: parsed.name,
                allowedMergeMethods: methods
            )
        } catch Error.other(let msg) where msg.lowercased().contains("no github") || msg.lowercased().contains("could not determine") {
            return nil
        }
    }

    /// Fetch latest PR + check rollup for each branch in a single GraphQL
    /// request. Branches without a PR on the remote are absent from the
    /// returned dictionary.
    ///
    /// We alias one `pullRequests(headRefName:)` field per branch (`b0`,
    /// `b1`, …) so the response groups results back together. Each alias
    /// returns the most recently created PR for that branch — typically only
    /// one exists, but `--state ALL` would otherwise need a per-branch call.
    static func batchFetchPRs(
        repo: RepoIdentifier,
        branches: [String],
        cwd: String
    ) async throws -> [String: (PullRequest, [CheckRun])] {
        guard !branches.isEmpty else { return [:] }

        let aliases = branches.enumerated().map { (alias: "b\($0.offset)", branch: $0.element) }
        let varDecls = (["$owner: String!", "$name: String!"]
            + aliases.map { "$\($0.alias): String!" }).joined(separator: ", ")
        let aliasFields = aliases.map { a in
            """
              \(a.alias): pullRequests(headRefName: $\(a.alias), first: 1, orderBy: {field: CREATED_AT, direction: DESC}, states: [OPEN, CLOSED, MERGED]) {
                nodes { ...PR }
              }
            """
        }.joined(separator: "\n")
        let query = """
        query(\(varDecls)) {
          repository(owner: $owner, name: $name) {
        \(aliasFields)
          }
        }
        fragment PR on PullRequest {
          number title url state isDraft headRefName baseRefName
          mergeable mergeStateStatus reviewDecision
          reviewThreads(first: 50) {
            nodes { isResolved }
            pageInfo { hasNextPage }
          }
          comments { totalCount }
          author { login }
          commits(last: 1) {
            nodes {
              commit {
                statusCheckRollup {
                  contexts(first: 100) {
                    nodes {
                      __typename
                      ... on CheckRun {
                        name status conclusion detailsUrl startedAt completedAt
                        checkSuite { workflowRun { workflow { name } } }
                      }
                      ... on StatusContext {
                        context state targetUrl createdAt
                      }
                    }
                    pageInfo { hasNextPage }
                  }
                }
              }
            }
          }
        }
        """

        var args: [String] = [
            "api", "graphql",
            "-F", "owner=\(repo.owner)",
            "-F", "name=\(repo.name)"
        ]
        for a in aliases { args.append(contentsOf: ["-F", "\(a.alias)=\(a.branch)"]) }
        args.append(contentsOf: ["-f", "query=\(query)"])

        let stdout = try await runGH(args, cwd: cwd)

        let response = try JSONDecoder().decode(GraphQLResponse<RepoBatch>.self, from: Data(stdout.utf8))
        if let errors = response.errors, !errors.isEmpty {
            throw Error.other(errors.map(\.message).joined(separator: "; "))
        }
        guard let aliasMap = response.data?.repository?.aliases else { return [:] }

        var out: [String: (PullRequest, [CheckRun])] = [:]
        for a in aliases {
            guard let result = aliasMap[a.alias],
                  let node = result.nodes.first else { continue }
            // Surface truncation as a warning so capped counts don't
            // silently drop tail review threads / check contexts on busy PRs.
            if node.reviewThreads?.pageInfo?.hasNextPage == true {
                print("batchFetchPRs: PR #\(node.number) in \(repo.owner)/\(repo.name) has more than 50 review threads; tail truncated.")
            }
            if node.commits?.nodes.first?.commit.statusCheckRollup?.contexts.pageInfo?.hasNextPage == true {
                print("batchFetchPRs: PR #\(node.number) in \(repo.owner)/\(repo.name) has more than 100 check contexts; tail truncated.")
            }
            out[a.branch] = (node.toPullRequest(), node.checkRuns)
        }
        return out
    }

    /// Merge a PR with the chosen strategy. Goes through `runGH` so the
    /// caller gets the same `ghMissing` / `authRequired` error mapping as
    /// the rest of the gh surface.
    static func mergePR(_ number: Int, method: MergeMethod, cwd: String) async throws {
        _ = try await runGH(["pr", "merge", String(number), method.ghFlag], cwd: cwd)
    }

    /// Open PRs on the repo, newest-update first. Slimmer than
    /// `batchFetchPRs` — the picker only needs enough metadata to render a
    /// row and decide forks. Capped at 100 (one GraphQL page); if the repo
    /// has more than 100 open PRs we log a warning so silent truncation
    /// can be diagnosed.
    static func listOpenPRs(
        repo: RepoIdentifier,
        cwd: String
    ) async throws -> [PRSummary] {
        let query = """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
            pullRequests(first: 100, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) {
              nodes {
                number title isDraft updatedAt
                headRefName baseRefName
                headRepositoryOwner { login }
                author { login }
                commits(last: 1) {
                  nodes {
                    commit { statusCheckRollup { state } }
                  }
                }
              }
              pageInfo { hasNextPage }
            }
          }
        }
        """
        let stdout = try await runGH(
            [
                "api", "graphql",
                "-F", "owner=\(repo.owner)",
                "-F", "name=\(repo.name)",
                "-f", "query=\(query)"
            ],
            cwd: cwd
        )
        let decoded = try JSONDecoder().decode(GraphQLResponse<OpenPRsRepo>.self, from: Data(stdout.utf8))
        if let errors = decoded.errors, !errors.isEmpty {
            throw Error.other(errors.map(\.message).joined(separator: "; "))
        }
        let connection = decoded.data?.repository?.pullRequests
        if connection?.pageInfo?.hasNextPage == true {
            print("listOpenPRs: \(repo.owner)/\(repo.name) has more than 100 open PRs; results truncated to first page.")
        }
        let nodes = connection?.nodes ?? []
        return nodes.compactMap { $0.toSummary() }
    }

    private static func runGH(_ args: [String], cwd: String) async throws -> String {
        let result = await Subprocess.run(
            executable: "/usr/bin/env",
            args: ["gh"] + args,
            cwd: cwd,
            env: [
                "NO_COLOR": "1",
                "GH_NO_UPDATE_NOTIFIER": "1",
                "GH_PAGER": ""
            ],
            closeStdin: true
        )
        if result.success { return result.stdout }

        let lower = result.stderr.lowercased()
        if result.status == -1 || lower.contains("command not found") || lower.contains("no such file") {
            throw Error.ghMissing
        }
        if lower.contains("authentication") || lower.contains("not logged into") || lower.contains("gh auth") {
            throw Error.authRequired
        }
        throw Error.other(result.stderr.nonBlank ?? "gh exited with status \(result.status)")
    }
}

// MARK: - GraphQL response wiring

private struct GraphQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GQLError]?
}

private struct GQLError: Decodable { let message: String }

/// Wrapper around `repository(...)` whose only purpose is to forward the
/// dynamic alias keys (`b0`, `b1`, …) into a `[String: PRBatchEntry]`.
private struct RepoBatch: Decodable {
    let repository: AliasedRepository?

    struct AliasedRepository: Decodable {
        let aliases: [String: PRBatchEntry]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: DynamicKey.self)
            var map: [String: PRBatchEntry] = [:]
            for key in c.allKeys {
                map[key.stringValue] = try c.decode(PRBatchEntry.self, forKey: key)
            }
            aliases = map
        }
    }
}

private struct DynamicKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(intValue _: Int) { return nil }
    init(stringValue: String) { self.stringValue = stringValue }
}

private struct PRBatchEntry: Decodable {
    let nodes: [PRNode]
}

private struct PRNode: Decodable {
    let number: Int
    let title: String
    let url: String
    let state: String
    let isDraft: Bool
    let headRefName: String
    let baseRefName: String
    let mergeable: String?
    let mergeStateStatus: String?
    let reviewDecision: String?
    let reviewThreads: ReviewThreadsConnection?
    let comments: CommentsConnection?
    let author: AuthorNode?
    let commits: CommitsConnection?

    struct AuthorNode: Decodable { let login: String }
    struct CommitsConnection: Decodable { let nodes: [CommitNode] }
    struct CommitNode: Decodable { let commit: CommitDetail }
    struct CommitDetail: Decodable { let statusCheckRollup: Rollup? }
    struct Rollup: Decodable { let contexts: ContextsConnection }
    struct ContextsConnection: Decodable {
        let nodes: [ContextNode]
        let pageInfo: PageInfo?
    }
    struct ReviewThreadsConnection: Decodable {
        let nodes: [ReviewThread]
        let pageInfo: PageInfo?
    }
    struct ReviewThread: Decodable { let isResolved: Bool }
    struct CommentsConnection: Decodable { let totalCount: Int }

    /// Either a CheckRun (Actions / GitHub App) or a StatusContext (legacy
    /// commit status). `__typename` discriminates; the other branch's fields
    /// are nil and the converter picks the right path.
    struct ContextNode: Decodable {
        let __typename: String
        // CheckRun
        let name: String?
        let status: CheckStatus?
        let conclusion: CheckConclusion?
        let detailsUrl: String?
        let startedAt: String?
        let completedAt: String?
        let checkSuite: CheckSuite?
        struct CheckSuite: Decodable { let workflowRun: WorkflowRun? }
        struct WorkflowRun: Decodable { let workflow: WorkflowName? }
        struct WorkflowName: Decodable { let name: String? }
        // StatusContext
        let context: String?
        let state: String?
        let targetUrl: String?
        let createdAt: String?
    }

    func toPullRequest() -> PullRequest {
        let unresolved = reviewThreads?.nodes.filter { !$0.isResolved }.count ?? 0
        return PullRequest(
            number: number,
            title: title,
            url: url,
            state: state,
            isDraft: isDraft,
            headRefName: headRefName,
            baseRefName: baseRefName,
            author: PullRequest.Author(login: author?.login ?? "unknown"),
            mergeable: mergeable,
            mergeStateStatus: mergeStateStatus,
            unresolvedThreadCount: unresolved,
            issueCommentCount: comments?.totalCount ?? 0,
            reviewDecision: reviewDecision
        )
    }

    var checkRuns: [CheckRun] {
        let contexts = commits?.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
        let raw: [CheckRun] = contexts.map { ctx in
            switch ctx.__typename {
            case "CheckRun":
                let status = ctx.status ?? .unknown
                let conclusion = ctx.conclusion ?? .unknown
                return CheckRun(
                    name: ctx.name ?? "(unnamed)",
                    status: status,
                    conclusion: conclusion,
                    bucket: CheckBucket.derive(status: status, conclusion: conclusion),
                    link: ctx.detailsUrl,
                    workflow: ctx.checkSuite?.workflowRun?.workflow?.name,
                    startedAt: ctx.startedAt,
                    completedAt: ctx.completedAt
                )
            default: // "StatusContext"
                let (status, conclusion, bucket): (CheckStatus, CheckConclusion, CheckBucket) = {
                    switch (ctx.state ?? "").uppercased() {
                    case "SUCCESS": return (.completed,  .success, .pass)
                    case "FAILURE", "ERROR": return (.completed, .failure, .fail)
                    case "PENDING", "EXPECTED": return (.inProgress, .unknown, .pending)
                    default: return (.unknown, .unknown, .unknown)
                    }
                }()
                return CheckRun(
                    name: ctx.context ?? "(unnamed)",
                    status: status,
                    conclusion: conclusion,
                    bucket: bucket,
                    link: ctx.targetUrl,
                    workflow: nil,
                    startedAt: ctx.createdAt,
                    completedAt: nil
                )
            }
        }

        // GitHub returns one entry per rerun, so the same (workflow, name)
        // can appear multiple times. Keep the latest by ISO 8601 timestamp.
        var deduped: [CheckRun] = []
        var indexById: [String: Int] = [:]
        for run in raw {
            if let idx = indexById[run.id] {
                if Self.recencyKey(run) > Self.recencyKey(deduped[idx]) {
                    deduped[idx] = run
                }
            } else {
                indexById[run.id] = deduped.count
                deduped.append(run)
            }
        }
        return deduped
    }

    private static func recencyKey(_ run: CheckRun) -> String {
        run.startedAt ?? run.completedAt ?? ""
    }
}

// MARK: - listOpenPRs response wiring

private struct PageInfo: Decodable {
    let hasNextPage: Bool
}

private struct OpenPRsRepo: Decodable {
    let repository: RepoConnection?
    struct RepoConnection: Decodable {
        let pullRequests: Nodes
    }
    struct Nodes: Decodable {
        let nodes: [PRSummaryNode]
        let pageInfo: PageInfo?
    }
}

private struct PRSummaryNode: Decodable {
    let number: Int
    let title: String
    let isDraft: Bool
    let updatedAt: String
    let headRefName: String
    let baseRefName: String
    let headRepositoryOwner: Owner?
    let author: Author?
    let commits: Commits?

    struct Owner: Decodable { let login: String }
    struct Author: Decodable { let login: String? }
    struct Commits: Decodable {
        let nodes: [CommitNode]
        struct CommitNode: Decodable { let commit: CommitDetail }
        struct CommitDetail: Decodable { let statusCheckRollup: Rollup? }
        struct Rollup: Decodable { let state: String }
    }

    func toSummary() -> PRSummary? {
        guard let date = ISO8601DateFormatter().date(from: updatedAt) else { return nil }
        let rollupState = commits?.nodes.first?.commit.statusCheckRollup?.state.uppercased()
        let bucket: CheckBucket? = {
            switch rollupState {
            case "SUCCESS": return .pass
            case "FAILURE", "ERROR": return .fail
            case "PENDING", "EXPECTED": return .pending
            case nil: return nil
            default: return .unknown
            }
        }()
        return PRSummary(
            number: number,
            title: title,
            authorLogin: author?.login ?? "unknown",
            headRefName: headRefName,
            headRepositoryOwner: headRepositoryOwner?.login ?? "",
            baseRefName: baseRefName,
            isDraft: isDraft,
            updatedAt: date,
            checkBucket: bucket
        )
    }
}
