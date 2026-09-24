import XCTest
@testable import JetlineApp

final class CheckpointerTests: XCTestCase {
    private var repo: URL!

    override func setUp() async throws {
        repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("jetline-checkpoint-\(UUID().uuidString.prefix(8))")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await git("init", "-q")
        try write("keep.txt", "one\ntwo\n")
        try write("edit.txt", "before\n")
        try write("gone.txt", "bye\n")
        try await git("add", ".")
        try await git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: repo)
    }

    func testCaptureDiffAndRestore() async throws {
        // Pre-existing uncommitted work, including a staged change.
        try write("draft.txt", "untracked draft\n")
        try write("keep.txt", "one\ntwo\nthree\n")
        try await git("add", "keep.txt")
        let statusBefore = try await git("status", "--porcelain")

        let before = try await XCTUnwrapAsync(await Checkpointer.capture(worktree: repo.path, ref: "refs/jetline/checkpoints/t/1-before"))

        // The "agent" edits, creates and deletes.
        try write("edit.txt", "after\n")
        try write("new/file.swift", "let x = 1\n")
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))

        let after = try await XCTUnwrapAsync(await Checkpointer.capture(worktree: repo.path, ref: "refs/jetline/checkpoints/t/1-after"))

        let stat = try await XCTUnwrapAsync(await Checkpointer.stat(worktree: repo.path, from: before, to: after))
        XCTAssertEqual(stat.files, 3)
        let diff = await Checkpointer.diff(worktree: repo.path, from: before, to: after)
        XCTAssertEqual(Set(diff.map(\.path)), ["edit.txt", "new/file.swift", "gone.txt"])
        XCTAssertEqual(diff.first { $0.path == "new/file.swift" }?.status, .added)
        XCTAssertEqual(diff.first { $0.path == "gone.txt" }?.status, .deleted)

        // Capturing must not touch the index.
        let statusAfterCapture = try await git("status", "--porcelain")
        XCTAssertTrue(statusAfterCapture.contains("M  keep.txt"), statusAfterCapture)

        try await Checkpointer.restore(worktree: repo.path, to: before)
        XCTAssertEqual(try read("edit.txt"), "before\n")
        XCTAssertEqual(try read("gone.txt"), "bye\n")
        XCTAssertEqual(try read("draft.txt"), "untracked draft\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("new/file.swift").path))
        // Worktree and index are exactly as they were before the turn.
        let statusAfterRestore = try await git("status", "--porcelain")
        XCTAssertEqual(statusAfterRestore, statusBefore)

        await Checkpointer.deleteRefs(worktree: repo.path, thread: "t")
        let refs = try await git("for-each-ref", "refs/jetline/")
        XCTAssertTrue(refs.isEmpty)
    }

    func testCaptureInRepoWithoutCommits() async throws {
        let empty = repo.appendingPathComponent("fresh")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        _ = try await GitRunner.runChecked(["init", "-q"], cwd: empty.path)
        try "hi\n".write(to: empty.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let commit = await Checkpointer.capture(worktree: empty.path, ref: nil)
        XCTAssertNotNil(commit)
    }

    func testCaptureSkipsNestedRepoWithoutCommits() async throws {
        let nested = repo.appendingPathComponent("vendor/lib")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        _ = try await GitRunner.runChecked(["init", "-q"], cwd: nested.path)
        try "x\n".write(to: nested.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try write("other.txt", "still captured\n")
        let before = try await git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await XCTUnwrapAsync(await Checkpointer.capture(worktree: repo.path, ref: nil))
        let diff = await Checkpointer.diff(worktree: repo.path, from: before, to: commit)
        XCTAssertTrue(diff.contains { $0.path == "other.txt" })
    }

    // MARK: Helpers

    @discardableResult
    private func git(_ args: String...) async throws -> String {
        try await GitRunner.runChecked(args, cwd: repo.path)
    }

    private func write(_ path: String, _ contents: String) throws {
        let url = repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
