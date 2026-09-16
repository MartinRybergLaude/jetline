import Foundation

/// A PR's comment stream: the description, top-level issue comments, review
/// summary bodies, and inline review threads, merged into one chronological
/// timeline.
///
/// Fetched on demand by `PRConversationStore`, deliberately *not* by
/// `PRTracker`. The tracker's batched query runs for every workspace in
/// every repo every 15–60s; carrying every comment body through it would
/// multiply both the response size and the GraphQL point cost for data
/// that's only ever looked at one PR at a time.
struct PRConversation: Sendable, Hashable {
    /// GraphQL node id of the pull request — `addComment`'s `subjectId`.
    var pullRequestId: String
    var number: Int
    /// The PR description, modelled as a comment so the timeline can render
    /// it with the same view. `nil` when the description is empty.
    var description: PRComment?
    var items: [PRTimelineItem]
    /// True when GitHub had more comments/threads than one page could hold.
    /// Surfaced in the UI so a capped list doesn't look like the whole story.
    var truncated: Bool
    /// Stored rather than derived: the toolbar reads them five times per
    /// render, and re-deriving would walk `items` and copy every thread
    /// (bodies, diff hunks, comment arrays) each time.
    var unresolvedCount: Int
    var resolvedCount: Int

    var isEmpty: Bool { description == nil && items.isEmpty }
}

/// One authored message: a top-level issue comment, or one comment inside an
/// inline review thread.
struct PRComment: Sendable, Hashable, Identifiable {
    var id: String
    var author: String
    var body: String
    var createdAt: Date
    var url: String
    /// GitHub-hidden comment (spam, off-topic, resolved). Rendered collapsed.
    var isMinimized: Bool
    var minimizedReason: String?
    /// Parsed at fetch time, off the main actor. Re-parsing in `body` would
    /// put a full markdown parse on every scroll frame.
    var blocks: [MarkdownBlock]

    init(
        id: String,
        author: String,
        body: String,
        createdAt: Date,
        url: String,
        isMinimized: Bool = false,
        minimizedReason: String? = nil
    ) {
        self.id = id
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.url = url
        self.isMinimized = isMinimized
        self.minimizedReason = minimizedReason
        self.blocks = MarkdownParser.parse(body)
    }
}

/// A submitted review's summary body — the text a reviewer writes above
/// their inline comments, plus the approve / request-changes verdict.
struct PRReview: Sendable, Hashable, Identifiable {
    enum Verdict: Sendable, Hashable {
        case approved, changesRequested, commented, dismissed

        init?(raw: String) {
            switch raw.uppercased() {
            case "APPROVED":          self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "COMMENTED":         self = .commented
            case "DISMISSED":         self = .dismissed
            // PENDING is an unsubmitted draft, visible only to its author
            // and not part of the conversation yet.
            default:                  return nil
            }
        }

        var label: String {
            switch self {
            case .approved:         return "approved"
            case .changesRequested: return "requested changes"
            case .commented:        return "reviewed"
            case .dismissed:        return "review dismissed"
            }
        }
    }

    var id: String
    var author: String
    var verdict: Verdict
    var submittedAt: Date
    var url: String
    var blocks: [MarkdownBlock]

    init(id: String, author: String, body: String, verdict: Verdict, submittedAt: Date, url: String) {
        self.id = id
        self.author = author
        self.verdict = verdict
        self.submittedAt = submittedAt
        self.url = url
        self.blocks = MarkdownParser.parse(body)
    }
}

/// An inline review thread anchored to a line of the diff.
struct PRReviewThread: Sendable, Hashable, Identifiable {
    var id: String
    var isResolved: Bool
    /// The anchored line no longer exists in the head commit — GitHub greys
    /// these out because the code they discuss has since changed.
    var isOutdated: Bool
    var path: String
    var line: Int?
    /// Unified diff context GitHub returns with the thread's first comment,
    /// pre-split. The card re-evaluates its body on every keystroke in the
    /// reply editor, and splitting there would redo the work each time.
    var diffHunkLines: [String]
    var comments: [PRComment]
    var viewerCanReply: Bool
    var viewerCanResolve: Bool
    var viewerCanUnresolve: Bool
    var resolvedBy: String?

    /// Threads sort by when the conversation started, not when it was last
    /// replied to — matching GitHub's own ordering in the Files tab.
    var createdAt: Date { comments.first?.createdAt ?? .distantPast }

    var location: String {
        guard let line else { return path }
        return "\(path):\(line)"
    }
}

enum PRTimelineItem: Sendable, Hashable, Identifiable {
    case comment(PRComment)
    case review(PRReview)
    case thread(PRReviewThread)

    var id: String {
        switch self {
        case let .comment(comment): return comment.id
        case let .review(review):   return review.id
        case let .thread(thread):   return thread.id
        }
    }

    var date: Date {
        switch self {
        case let .comment(comment): return comment.createdAt
        case let .review(review):   return review.submittedAt
        case let .thread(thread):   return thread.createdAt
        }
    }

    var isResolvedThread: Bool {
        if case let .thread(thread) = self { return thread.isResolved }
        return false
    }
}

/// Mirrors `PRSnapshot`'s shape. `.idle` is the extra state: conversations
/// are only fetched once the Comments tab asks for them, so "never loaded"
/// has to be distinguishable from "loading".
enum PRConversationSnapshot: Equatable, Sendable {
    case idle
    case loading
    case error(String)
    case loaded(PRConversation)

    var conversation: PRConversation? {
        if case let .loaded(conversation) = self { return conversation }
        return nil
    }
}

// MARK: - gh wiring

extension GitHubRunner {
    private static let conversationQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          id number body createdAt url
          author { login }
          comments(first: 100) {
            nodes {
              id body createdAt url isMinimized minimizedReason
              author { login }
            }
            pageInfo { hasNextPage }
          }
          reviews(first: 100) {
            nodes {
              id body state submittedAt url
              author { login }
            }
            pageInfo { hasNextPage }
          }
          reviewThreads(first: 100) {
            nodes {
              id isResolved isOutdated path line originalLine
              viewerCanReply viewerCanResolve viewerCanUnresolve
              resolvedBy { login }
              comments(first: 100) {
                nodes {
                  id body createdAt url diffHunk isMinimized minimizedReason
                  author { login }
                }
                pageInfo { hasNextPage }
              }
            }
            pageInfo { hasNextPage }
          }
        }
      }
    }
    """

    /// Fetch the full comment stream for one PR.
    ///
    /// Returns `nil` when the PR number no longer resolves (deleted, or the
    /// workspace's stored identity is stale), which the caller reports as an
    /// absent conversation rather than an error.
    static func fetchConversation(
        repo: RepoIdentifier,
        number: Int,
        cwd: String
    ) async throws -> PRConversation? {
        let stdout = try await runGH(
            [
                "api", "graphql",
                "-F", "owner=\(repo.owner)",
                "-F", "name=\(repo.name)",
                "-F", "number=\(number)",
                "-f", "query=\(conversationQuery)"
            ],
            cwd: cwd
        )
        return try decodeConversation(Data(stdout.utf8), repo: repo)
    }

    /// Split out from `fetchConversation` so the response shape can be
    /// exercised without a network round trip.
    static func decodeConversation(_ data: Data, repo: RepoIdentifier) throws -> PRConversation? {
        let response = try JSONDecoder().decode(GraphQLResponse<ConversationData>.self, from: data)
        if let errors = response.errors, !errors.isEmpty {
            throw Error.other(errors.map(\.message).joined(separator: "; "))
        }
        guard let node = response.data?.repository?.pullRequest else { return nil }
        return node.toConversation(repo: repo)
    }

    /// Post a top-level comment on the PR's conversation.
    static func addIssueComment(pullRequestId: String, body: String, cwd: String) async throws {
        try await runMutation(
            """
            mutation($subjectId: ID!, $body: String!) {
              addComment(input: {subjectId: $subjectId, body: $body}) {
                clientMutationId
              }
            }
            """,
            fields: ["subjectId": pullRequestId, "body": body],
            cwd: cwd
        )
    }

    /// Reply to an existing inline review thread.
    static func replyToReviewThread(threadId: String, body: String, cwd: String) async throws {
        try await runMutation(
            """
            mutation($threadId: ID!, $body: String!) {
              addPullRequestReviewThreadReply(
                input: {pullRequestReviewThreadId: $threadId, body: $body}
              ) {
                clientMutationId
              }
            }
            """,
            fields: ["threadId": threadId, "body": body],
            cwd: cwd
        )
    }

    static func setReviewThreadResolved(threadId: String, resolved: Bool, cwd: String) async throws {
        let mutation = resolved
            ? """
              mutation($threadId: ID!) {
                resolveReviewThread(input: {threadId: $threadId}) { clientMutationId }
              }
              """
            : """
              mutation($threadId: ID!) {
                unresolveReviewThread(input: {threadId: $threadId}) { clientMutationId }
              }
              """
        try await runMutation(mutation, fields: ["threadId": threadId], cwd: cwd)
    }

    /// All variables go through `-f` (raw string), never `-F`. `-F` applies
    /// gh's value coercion: a body starting with `@` would be read as a
    /// filename, and one that looks like a number or `true` would be sent as
    /// the wrong JSON type.
    private static func runMutation(
        _ mutation: String,
        fields: [String: String],
        cwd: String
    ) async throws {
        var args = ["api", "graphql", "-f", "query=\(mutation)"]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-f", "\(key)=\(value)"])
        }
        let stdout = try await runGH(args, cwd: cwd)
        // gh exits non-zero on GraphQL errors, so reaching here usually means
        // success — but a partial-data response still carries an `errors`
        // array with a 200, and silently swallowing it would make a failed
        // resolve look like it worked.
        let response = try? JSONDecoder().decode(
            GraphQLResponse<EmptyPayload>.self,
            from: Data(stdout.utf8)
        )
        if let errors = response?.errors, !errors.isEmpty {
            throw Error.other(errors.map(\.message).joined(separator: "; "))
        }
    }
}

private struct EmptyPayload: Decodable {}

// MARK: - Conversation response wiring

private struct ConversationData: Decodable {
    let repository: RepositoryNode?
    struct RepositoryNode: Decodable {
        let pullRequest: ConversationNode?
    }
}

private struct ConversationNode: Decodable {
    let id: String
    let number: Int
    let body: String?
    let createdAt: String?
    let url: String
    let author: Login?
    let comments: Connection<IssueCommentNode>?
    let reviews: Connection<ReviewNode>?
    let reviewThreads: Connection<ThreadNode>?

    struct Login: Decodable { let login: String? }

    struct Connection<Node: Decodable>: Decodable {
        let nodes: [Node]?
        let pageInfo: PageInfo?
    }

    struct IssueCommentNode: Decodable {
        let id: String
        let body: String?
        let createdAt: String?
        let url: String?
        let isMinimized: Bool?
        let minimizedReason: String?
        let author: Login?
    }

    struct ReviewNode: Decodable {
        let id: String
        let body: String?
        let state: String?
        let submittedAt: String?
        let url: String?
        let author: Login?
    }

    struct ThreadNode: Decodable {
        let id: String
        let isResolved: Bool?
        let isOutdated: Bool?
        let path: String?
        let line: Int?
        let originalLine: Int?
        let viewerCanReply: Bool?
        let viewerCanResolve: Bool?
        let viewerCanUnresolve: Bool?
        let resolvedBy: Login?
        let comments: Connection<ThreadCommentNode>?
    }

    struct ThreadCommentNode: Decodable {
        let id: String
        let body: String?
        let createdAt: String?
        let url: String?
        let diffHunk: String?
        let isMinimized: Bool?
        let minimizedReason: String?
        let author: Login?
    }

    func toConversation(repo: RepoIdentifier) -> PRConversation {
        var items: [PRTimelineItem] = []

        for node in comments?.nodes ?? [] {
            items.append(.comment(PRComment(
                id: node.id,
                author: node.author?.login ?? "ghost",
                body: node.body ?? "",
                createdAt: GitHubTimestamp.date(node.createdAt) ?? .distantPast,
                url: node.url ?? url,
                isMinimized: node.isMinimized ?? false,
                minimizedReason: node.minimizedReason?.nonBlank
            )))
        }

        for node in reviews?.nodes ?? [] {
            guard let verdict = PRReview.Verdict(raw: node.state ?? "") else { continue }
            let body = node.body ?? ""
            // A COMMENTED review with no body is just the envelope GitHub
            // wraps around inline comments — the threads carry the content,
            // and rendering the envelope too would double every review.
            if body.nonBlank == nil && verdict == .commented { continue }
            items.append(.review(PRReview(
                id: node.id,
                author: node.author?.login ?? "ghost",
                body: body,
                verdict: verdict,
                submittedAt: GitHubTimestamp.date(node.submittedAt) ?? .distantPast,
                url: node.url ?? url
            )))
        }

        for node in reviewThreads?.nodes ?? [] {
            let comments = (node.comments?.nodes ?? []).map { comment in
                PRComment(
                    id: comment.id,
                    author: comment.author?.login ?? "ghost",
                    body: comment.body ?? "",
                    createdAt: GitHubTimestamp.date(comment.createdAt) ?? .distantPast,
                    url: comment.url ?? url,
                    isMinimized: comment.isMinimized ?? false,
                    minimizedReason: comment.minimizedReason?.nonBlank
                )
            }
            guard !comments.isEmpty else { continue }
            items.append(.thread(PRReviewThread(
                id: node.id,
                isResolved: node.isResolved ?? false,
                isOutdated: node.isOutdated ?? false,
                path: node.path ?? "",
                // `line` is null once the thread's anchor falls out of the
                // current diff; `originalLine` still points at the code the
                // reviewer was looking at.
                line: node.line ?? node.originalLine,
                diffHunkLines: (node.comments?.nodes?.first?.diffHunk).map {
                    $0.components(separatedBy: "\n")
                } ?? [],
                comments: comments,
                viewerCanReply: node.viewerCanReply ?? false,
                viewerCanResolve: node.viewerCanResolve ?? false,
                viewerCanUnresolve: node.viewerCanUnresolve ?? false,
                resolvedBy: node.resolvedBy?.login
            )))
        }

        items.sort { lhs, rhs in
            // Ids break ties so a refresh can't reorder items posted in the
            // same second, which would otherwise shuffle rows under the user.
            lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date < rhs.date
        }

        let description = (body?.nonBlank).map {
            PRComment(
                id: "pr-body-\(id)",
                author: author?.login ?? "ghost",
                body: $0,
                createdAt: GitHubTimestamp.date(createdAt) ?? .distantPast,
                url: url
            )
        }

        let truncated = [
            comments?.pageInfo?.hasNextPage,
            reviews?.pageInfo?.hasNextPage,
            reviewThreads?.pageInfo?.hasNextPage
        ].contains(true)
        if truncated {
            print("fetchConversation: PR #\(number) in \(repo.owner)/\(repo.name) has more than 100 comments/reviews/threads; tail truncated.")
        }

        var unresolved = 0
        var resolved = 0
        for case let .thread(thread) in items {
            if thread.isResolved { resolved += 1 } else { unresolved += 1 }
        }

        return PRConversation(
            pullRequestId: id,
            number: number,
            description: description,
            items: items,
            truncated: truncated,
            unresolvedCount: unresolved,
            resolvedCount: resolved
        )
    }
}
