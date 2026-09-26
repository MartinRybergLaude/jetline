import XCTest
@testable import JetlineApp

final class MergeCleanupPolicyTests: XCTestCase {
    func testMergedBeforeWorkspaceCreationDoesNotDelete() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "MERGED", mergedAt: date("2026-06-30T11:59:59Z"))

        XCTAssertFalse(MergeCleanupPolicy.shouldDelete(workspace: workspace, pr: pr))
    }

    func testMergedAfterWorkspaceCreationDeletes() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "MERGED", mergedAt: date("2026-06-30T12:00:01Z"))

        XCTAssertTrue(MergeCleanupPolicy.shouldDelete(workspace: workspace, pr: pr))
    }

    func testMergedWithoutMergedAtDoesNotDelete() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "MERGED", mergedAt: nil)

        XCTAssertFalse(MergeCleanupPolicy.shouldDelete(workspace: workspace, pr: pr))
    }

    func testOpenPRDoesNotDelete() {
        let workspace = makeWorkspace(createdAt: date("2026-06-30T12:00:00Z"))
        let pr = makePR(state: "OPEN", mergedAt: date("2026-06-30T12:00:01Z"))

        XCTAssertFalse(MergeCleanupPolicy.shouldDelete(workspace: workspace, pr: pr))
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

    func testLocalWorkBlocksDelete() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetline-merge-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git").path
        let clone = root.appendingPathComponent("clone").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await git(["init", "-q", "--bare", remote], in: root.path)
        try await git(["clone", "-q", remote, clone], in: root.path)
        let commit = ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "c"]
        try "one\n".write(toFile: clone + "/a.txt", atomically: true, encoding: .utf8)
        try await git(["add", "."], in: clone)
        try await git(commit, in: clone)
        try await git(["push", "-q", "origin", "HEAD"], in: clone)

        let pushedAndClean = await MergeCleanupPolicy.hasNoLocalWork(worktreePath: clone)
        XCTAssertTrue(pushedAndClean)

        try "two\n".write(toFile: clone + "/a.txt", atomically: true, encoding: .utf8)
        let dirty = await MergeCleanupPolicy.hasNoLocalWork(worktreePath: clone)
        XCTAssertFalse(dirty)

        try await git(["add", "."], in: clone)
        try await git(commit, in: clone)
        let unpushed = await MergeCleanupPolicy.hasNoLocalWork(worktreePath: clone)
        XCTAssertFalse(unpushed)

        let missing = await MergeCleanupPolicy.hasNoLocalWork(worktreePath: root.appendingPathComponent("nope").path)
        XCTAssertFalse(missing)
    }

    private func git(_ args: [String], in cwd: String) async throws {
        let result = try await GitRunner.run(args, cwd: cwd)
        XCTAssertTrue(result.success, "git \(args.joined(separator: " "))")
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
