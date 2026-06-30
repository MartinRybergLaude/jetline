import XCTest
@testable import JetlineApp

final class MergeCleanupPolicyTests: XCTestCase {
    func testMergedBeforeWorkspaceCreationDoesNotArchive() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "MERGED", mergedAt: date("2026-06-30T11:59:59Z"))

        XCTAssertFalse(MergeCleanupPolicy.shouldArchive(workspace: workspace, pr: pr))
    }

    func testMergedAfterWorkspaceCreationArchives() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "MERGED", mergedAt: date("2026-06-30T12:00:01Z"))

        XCTAssertTrue(MergeCleanupPolicy.shouldArchive(workspace: workspace, pr: pr))
    }

    func testMergedWithoutMergedAtDoesNotArchive() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "MERGED", mergedAt: nil)

        XCTAssertFalse(MergeCleanupPolicy.shouldArchive(workspace: workspace, pr: pr))
    }

    func testOpenPRDoesNotArchive() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "OPEN", mergedAt: date("2026-06-30T12:00:01Z"))

        XCTAssertFalse(MergeCleanupPolicy.shouldArchive(workspace: workspace, pr: pr))
    }

    func testPullRequestDecodesOldSnapshotWithoutTimestamps() throws {
        let json = """
        {
          "number": 42,
          "title": "Test PR",
          "url": "https://example.com/pr/42",
          "state": "OPEN",
          "isDraft": false,
          "headRefName": "feature/x",
          "baseRefName": "main",
          "author": { "login": "tester" }
        }
        """

        let pr = try decoder.decode(PullRequest.self, from: Data(json.utf8))

        XCTAssertNil(pr.createdAt)
        XCTAssertNil(pr.mergedAt)
    }

    func testPullRequestDecodesTimestamps() throws {
        let json = """
        {
          "number": 42,
          "title": "Test PR",
          "url": "https://example.com/pr/42",
          "state": "MERGED",
          "isDraft": false,
          "headRefName": "feature/x",
          "baseRefName": "main",
          "author": { "login": "tester" },
          "createdAt": "2026-06-30T11:00:00Z",
          "mergedAt": "2026-06-30T12:00:00Z"
        }
        """

        let pr = try decoder.decode(PullRequest.self, from: Data(json.utf8))

        XCTAssertEqual(pr.createdAt, date("2026-06-30T11:00:00Z"))
        XCTAssertEqual(pr.mergedAt, date("2026-06-30T12:00:00Z"))
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeWorkspace(createdAt: Date) -> Workspace {
        Workspace(
            id: "ws1",
            repositoryId: "repo1",
            name: "Test",
            branchName: "feature/x",
            baseBranch: "main",
            worktreePath: "/tmp/wt",
            agent: .claude,
            createdAt: createdAt,
            lastActiveAt: createdAt
        )
    }

    private func makePR(state: String, mergedAt: Date?) -> PullRequest {
        PullRequest(
            number: 42,
            title: "Test PR",
            url: "https://example.com/pr/42",
            state: state,
            isDraft: false,
            headRefName: "feature/x",
            baseRefName: "main",
            author: PullRequest.Author(login: "tester"),
            mergedAt: mergedAt
        )
    }

    private func date(_ raw: String) -> Date {
        ISO8601DateFormatter().date(from: raw)!
    }
}
