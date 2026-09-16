import XCTest
@testable import JetlineApp

final class PRConversationTests: XCTestCase {
    private let repo = RepoIdentifier(owner: "acme", name: "widget", allowedMergeMethods: [])

    private func decode(_ json: String) throws -> PRConversation? {
        try GitHubRunner.decodeConversation(Data(json.utf8), repo: repo)
    }

    /// Mirrors the live `reviewThreads` / `reviews` / `comments` response
    /// shape, including the fields GitHub returns empty rather than null.
    private let sample = """
    {"data":{"repository":{"pullRequest":{
      "id":"PR_1","number":7,"url":"https://github.com/acme/widget/pull/7",
      "body":"## Summary\\n\\nDoes a thing.","createdAt":"2026-01-01T09:00:00Z",
      "author":{"login":"alice"},
      "comments":{"nodes":[
        {"id":"IC_1","body":"looks good","createdAt":"2026-01-01T12:00:00Z",
         "url":"https://example.com/ic1","isMinimized":false,"minimizedReason":"",
         "author":{"login":"bob"}}
      ],"pageInfo":{"hasNextPage":false}},
      "reviews":{"nodes":[
        {"id":"PRR_1","body":"Nice work","state":"APPROVED",
         "submittedAt":"2026-01-01T13:00:00Z","url":"https://example.com/r1",
         "author":{"login":"carol"}},
        {"id":"PRR_2","body":"","state":"COMMENTED",
         "submittedAt":"2026-01-01T10:00:00Z","url":"https://example.com/r2",
         "author":{"login":"carol"}},
        {"id":"PRR_3","body":"draft","state":"PENDING",
         "submittedAt":null,"url":"https://example.com/r3",
         "author":{"login":"alice"}}
      ],"pageInfo":{"hasNextPage":false}},
      "reviewThreads":{"nodes":[
        {"id":"T_1","isResolved":false,"isOutdated":false,"path":"Sources/A.swift",
         "line":42,"originalLine":40,"viewerCanReply":true,"viewerCanResolve":true,
         "viewerCanUnresolve":false,"resolvedBy":null,
         "comments":{"nodes":[
           {"id":"RC_1","body":"this traps","createdAt":"2026-01-01T11:00:00Z",
            "url":"https://example.com/rc1","diffHunk":"@@ -1 +1 @@\\n+let x = 1",
            "isMinimized":false,"minimizedReason":"",
            "author":{"login":"carol"}}
         ],"pageInfo":{"hasNextPage":false}}},
        {"id":"T_2","isResolved":true,"isOutdated":true,"path":"Sources/B.swift",
         "line":null,"originalLine":8,"viewerCanReply":true,"viewerCanResolve":false,
         "viewerCanUnresolve":true,"resolvedBy":{"login":"alice"},
         "comments":{"nodes":[
           {"id":"RC_2","body":"nit","createdAt":"2026-01-01T14:00:00Z",
            "url":"https://example.com/rc2","diffHunk":"","isMinimized":false,
            "minimizedReason":"","author":{"login":"dave"}}
         ],"pageInfo":{"hasNextPage":false}}}
      ],"pageInfo":{"hasNextPage":false}}
    }}}}
    """

    func testDecodesDescriptionAndTimeline() throws {
        let conversation = try XCTUnwrap(decode(sample))
        XCTAssertEqual(conversation.pullRequestId, "PR_1")
        XCTAssertEqual(conversation.number, 7)
        XCTAssertEqual(conversation.description?.author, "alice")
        XCTAssertEqual(conversation.description?.blocks.first, .heading(level: 2, text: "Summary"))
        XCTAssertFalse(conversation.truncated)
    }

    func testTimelineIsChronological() throws {
        let conversation = try XCTUnwrap(decode(sample))
        XCTAssertEqual(conversation.items.map(\.id), ["T_1", "IC_1", "PRR_1", "T_2"])
    }

    /// An empty COMMENTED review is the envelope around inline comments, and
    /// a PENDING one is an unsubmitted draft — neither is a timeline entry.
    func testEmptyAndPendingReviewsAreDropped() throws {
        let conversation = try XCTUnwrap(decode(sample))
        XCTAssertFalse(conversation.items.contains { $0.id == "PRR_2" })
        XCTAssertFalse(conversation.items.contains { $0.id == "PRR_3" })
    }

    func testThreadCountsAndFallbacks() throws {
        let conversation = try XCTUnwrap(decode(sample))
        XCTAssertEqual(conversation.unresolvedCount, 1)
        XCTAssertEqual(conversation.resolvedCount, 1)

        let threads: [PRReviewThread] = conversation.items.compactMap {
            if case let .thread(thread) = $0 { return thread } else { return nil }
        }
        XCTAssertEqual(threads[0].location, "Sources/A.swift:42")
        XCTAssertEqual(threads[0].diffHunkLines, ["@@ -1 +1 @@", "+let x = 1"])
        // `line` is null once the anchor falls out of the current diff.
        XCTAssertEqual(threads[1].line, 8)
        XCTAssertEqual(threads[1].resolvedBy, "alice")
        XCTAssertTrue(threads[1].isOutdated)
    }

    func testEmptyStringMinimizedReasonIsTreatedAsAbsent() throws {
        let conversation = try XCTUnwrap(decode(sample))
        guard case let .comment(comment)? = conversation.items.first(where: { $0.id == "IC_1" }) else {
            return XCTFail("expected the issue comment")
        }
        XCTAssertNil(comment.minimizedReason)
    }

    func testTruncationIsReported() throws {
        let truncated = sample.replacingOccurrences(
            of: "\"reviewThreads\":{\"nodes\":[",
            with: "\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":true},\"nodes\":["
        )
        XCTAssertTrue(try XCTUnwrap(decode(truncated)).truncated)
    }

    func testMissingPullRequestDecodesToNil() throws {
        XCTAssertNil(try decode(#"{"data":{"repository":{"pullRequest":null}}}"#))
    }

    func testGraphQLErrorsAreSurfaced() {
        let json = #"{"data":null,"errors":[{"message":"Could not resolve to a Repository"}]}"#
        XCTAssertThrowsError(try decode(json)) { error in
            XCTAssertTrue("\(error)".contains("Could not resolve"))
        }
    }

    func testEmptyBodyProducesNoDescription() throws {
        let blank = sample.replacingOccurrences(
            of: "\"body\":\"## Summary\\n\\nDoes a thing.\"",
            with: "\"body\":\"\""
        )
        XCTAssertNil(try XCTUnwrap(decode(blank)).description)
    }
}
