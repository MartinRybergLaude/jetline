import XCTest
@testable import JetlineApp
#if canImport(Glibc)
import Glibc
#endif

/// Buffers that keep only a tail of what passes through them must not keep
/// the rest resident: `Data.removeFirst(_:)` re-slices rather than freeing,
/// so a "capped" buffer trimmed that way grows with everything ever written.
final class MemoryRetentionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        signal(SIGPIPE, SIG_IGN)
        _ = TestSupport.dataDir
    }

    private static let chunk = Data(repeating: 0x41, count: 64 * 1024)
    /// Far more than any of these buffers may hold.
    private static let written = 256 * 1024 * 1024
    /// What a bounded buffer may leave resident, with room for allocator noise.
    private static let allowedGrowth = 64 * 1024 * 1024

    func testTrimmedDataKeepsNoDroppedBytes() {
        var data = Data(repeating: 1, count: 10)
        data.append(Data(repeating: 2, count: 4))
        data.removePrefix(10)
        XCTAssertEqual(data, Data(repeating: 2, count: 4))
        XCTAssertEqual(data.startIndex, 0, "trimmed in place, not re-sliced over the old storage")
        data.removePrefix(99)
        XCTAssertTrue(data.isEmpty)
    }

    func testTerminalBufferKeepsOnlyItsCapacity() {
        let capacity = 1024 * 1024
        let buffer = TerminalBuffer(capacity: capacity)
        let before = Memory.residentBytes()
        for _ in 0..<(Self.written / Self.chunk.count) { _ = buffer.append(Self.chunk) }
        let grown = Memory.residentBytes() - before
        withExtendedLifetime(buffer) {
            XCTAssertLessThan(grown, Self.allowedGrowth, "a \(capacity)-byte terminal buffer kept \(grown) bytes")
        }
        // Offsets and reads are unchanged by how the storage is trimmed.
        let range = buffer.range
        XCTAssertEqual(range.end, UInt64(Self.written))
        XCTAssertLessThanOrEqual(range.end - range.start, UInt64(capacity))
        let (from, bytes) = buffer.read(from: range.end - 10)
        XCTAssertEqual(from, range.end - 10)
        XCTAssertEqual(bytes, Data(repeating: 0x41, count: 10))
    }

    func testAgentStderrKeepsOnlyItsTail() async throws {
        let process = JSONLineProcess(.init(
            executable: "/bin/sh",
            args: ["-c", "head -c \(Self.written) /dev/zero >&2"],
            cwd: TestSupport.dataDir.path,
            env: ProcessInfo.processInfo.environment
        ))
        let before = Memory.residentBytes()
        try process.start()
        let status = await process.waitForExit()
        let grown = Memory.residentBytes() - before
        XCTAssertEqual(status, 0)
        XCTAssertEqual(process.stderrTail.utf8.count, 16 * 1024)
        XCTAssertLessThan(grown, Self.allowedGrowth, "the agent's stderr tail kept \(grown) bytes")
    }

    func testToolClientKeepsNoAnsweredReplies() throws {
        let path = JetlineDaemon.socketPath(named: "memtest-\(UUID().uuidString.prefix(8))")
        let listener = try Sockets.listen(path: path)
        defer {
            _ = close(listener)
            unlink(path)
        }
        let reply = String(repeating: "x", count: 1024 * 1024)
        Thread { Self.answerEveryRequest(on: listener, with: reply) }.start()

        let client = try BlockingEngineClient(socketPath: path, clientName: "memory-test")
        let before = Memory.residentBytes()
        // As `jetlined mcp` calls it: one pool per request.
        for _ in 0..<(Self.written / reply.utf8.count) {
            _ = try drainingAutoreleases { try client.call("ping", .object([:])) }
        }
        let grown = Memory.residentBytes() - before
        withExtendedLifetime(client) {
            XCTAssertLessThan(grown, Self.allowedGrowth, "the tool client kept \(grown) bytes of replies")
        }
    }

    /// `jetlined mcp` reads requests in a loop that never returns to a run
    /// loop; what JSONSerialization autoreleases must go each pass.
    func testJSONParsedInALoopIsFreedEachPass() {
        let line = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"\#(String(repeating: "x", count: 1024 * 1024))"}}"#.utf8)
        let before = Memory.residentBytes()
        for _ in 0..<(Self.written / line.count) {
            drainingAutoreleases { _ = try? JSONValue.parse(line) }
        }
        let grown = Memory.residentBytes() - before
        XCTAssertLessThan(grown, Self.allowedGrowth, "parsing kept \(grown) bytes")
    }

    func testFinishedSubprocessesKeepNoOutput() async {
        let output = 1024 * 1024
        let before = Memory.residentBytes()
        for _ in 0..<(Self.written / output) {
            let result = await Subprocess.run(executable: "/bin/sh", args: ["-c", "head -c \(output) /dev/zero"])
            XCTAssertEqual(result.stdout.utf8.count, output)
        }
        let grown = Memory.residentBytes() - before
        XCTAssertLessThan(grown, Self.allowedGrowth, "finished subprocesses kept \(grown) bytes")
    }

    func testFinishedProcessIsReleased() async {
        weak var released: Process?
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 0"]
            process.terminationHandler = { proc in
                proc.releaseRunLoopSource()
                cont.resume()
            }
            released = process
            try? process.run()
        }
        for _ in 0..<50 where released != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(released, "a finished Process stayed alive")
    }

    func testRemoteStderrTailKeepsOnlyItsTail() {
        let tail = StderrTail()
        let before = Memory.residentBytes()
        for _ in 0..<(Self.written / Self.chunk.count) { tail.append(Self.chunk) }
        let grown = Memory.residentBytes() - before
        withExtendedLifetime(tail) {
            XCTAssertLessThan(grown, Self.allowedGrowth, "the ssh stderr tail kept \(grown) bytes")
        }
        XCTAssertEqual(tail.text.utf8.count, 4096)
    }

    #if os(macOS)
    func testRunOutputCaptureKeepsOnlyItsCap() {
        let capture = OutputCapture()
        let before = Memory.residentBytes()
        for _ in 0..<(Self.written / Self.chunk.count) { capture.append(Self.chunk) }
        let grown = Memory.residentBytes() - before
        withExtendedLifetime(capture) {
            XCTAssertLessThan(grown, Self.allowedGrowth, "the run output capture kept \(grown) bytes")
        }
        XCTAssertLessThanOrEqual(capture.text.utf8.count, 200_000)
    }
    #endif

    #if os(Linux)
    /// A connection's inbox grows to fit the largest burst it reads (an
    /// uploaded file arrives as one frame); once that is delivered, the
    /// connection must not hold the room for the rest of its life. Linux
    /// only: on macOS a burst this size leaves ~256 MB of footprint behind
    /// with or without the fix, so the measure can't see it there.
    func testConnectionKeepsNoRoomFromABurst() async throws {
        let (a, b) = try XCTUnwrap(Sockets.pair())
        defer { _ = close(b) }
        let connection = FramedConnection(readFD: a, writeFD: a, label: "memory-test")
        let delivered = Locked(0)
        connection.onFrames = { batch in delivered.mutate { $0 += batch.count } }
        connection.start()
        defer { connection.close() }

        let burst = FramedConnection.frame(.message, Data(repeating: 0x41, count: Self.written / 2))
        let before = Memory.residentBytes()
        await TestIO.background { _ = writeAll(fd: b, burst) }.value
        await eventually("the burst") { delivered.value == 1 }
        let grown = Memory.residentBytes() - before
        withExtendedLifetime(burst) {}
        XCTAssertLessThan(grown, Self.allowedGrowth, "the connection kept \(grown) bytes after the burst")
    }
    #endif

    #if os(Linux)
    /// The daemon's churn, many threads at once: each reads a reply of up to
    /// a few MB into a growing `Data` (a `gh` or `git` poll), parses it into
    /// thousands of small objects and keeps a handful. glibc kept the freed
    /// rest in its arenas instead of returning it.
    ///
    /// In a process of its own, started like the daemon: the tuning has to
    /// come before threads claim arenas, and earlier tests here have claimed
    /// dozens.
    func testChurnedHeapGoesBackToTheSystem() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["JetlineAppTests.MemoryRetentionTests/testChurnInThisProcess"]
        child.environment = ProcessInfo.processInfo.environment.merging([Self.churnChild: "1"]) { $1 }
        let output = Pipe()
        child.standardOutput = output
        child.standardError = output
        try child.run()
        let report = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        let failures = report.split(separator: "\n").filter { $0.contains("error:") }.joined(separator: "\n")
        XCTAssertEqual(child.terminationStatus, 0, failures.isEmpty ? report : failures)
        XCTAssertTrue(report.contains("testChurnInThisProcess' passed"), report)
    }

    private static let churnChild = "JETLINE_CHURN_CHILD"

    func testChurnInThisProcess() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[Self.churnChild] != nil, "run by testChurnedHeapGoesBackToTheSystem")
        Heap.tune()
        let piece = Data(repeating: 0x41, count: 16 * 1024)
        let kept = Survivors()
        let before = Memory.residentBytes()
        // Threads, not `concurrentPerform`: the daemon blocks dozens of them
        // (subprocess waits, socket writes), and glibc gives each its own arena.
        let done = DispatchGroup()
        for worker in 0..<64 {
            done.enter()
            Thread {
                for round in 0..<12 {
                    var reply = Data()
                    for _ in 0..<(16 + (worker * 7 + round * 13) % 192) { reply.append(piece) }
                    let parsed = (0..<4000).map { String(repeating: "x", count: 32 + ($0 * 31 + worker) % 400) }
                    kept.add(parsed[(worker + round) % parsed.count])
                    withExtendedLifetime(reply) {}
                }
                done.leave()
            }.start()
        }
        done.wait()
        Heap.trim()
        let grown = Memory.residentBytes() - before
        withExtendedLifetime(kept) {
            XCTAssertLessThan(grown, Self.allowedGrowth, "the allocator kept \(grown) bytes of freed churn")
        }
    }

    private final class Survivors: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.withLock { items.append(item) } }
    }
    #endif

    /// A stand-in engine: answers every framed request with `reply` as its
    /// result, until the client hangs up.
    private static func answerEveryRequest(on listener: Int32, with reply: String) {
        guard let fd = Sockets.accept(listener) else { return }
        defer { _ = close(fd) }
        var inbox = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return }
            inbox.append(contentsOf: buffer[0..<n])
            while inbox.count >= 4 {
                let length = inbox.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard inbox.count >= 4 + length else { break }
                let body = inbox.subdata(in: (inbox.startIndex + 5)..<(inbox.startIndex + 4 + length))
                inbox = inbox.subdata(in: (inbox.startIndex + 4 + length)..<inbox.endIndex)
                guard let id = (try? JSONValue.parse(body))?["id"]?.int else { continue }
                let response = Data(#"{"type":"response","id":\#(id),"result":"\#(reply)"}"#.utf8)
                guard writeAll(fd: fd, FramedConnection.frame(.message, response)) == nil else { return }
            }
        }
    }
}

/// This process's resident memory.
enum Memory {
    static func residentBytes() -> Int {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size) : 0
        #else
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = statm.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return 0 }
        return pages * Int(sysconf(Int32(_SC_PAGESIZE)))
        #endif
    }

    #if os(Linux)
    /// The most this process has had resident since `resetPeak()`.
    static func peakResidentBytes() -> Int {
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
              let line = status.split(separator: "\n").first(where: { $0.hasPrefix("VmHWM:") }),
              let kb = line.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { return 0 }
        return kb * 1024
    }

    static func resetPeak() {
        try? "5".write(toFile: "/proc/self/clear_refs", atomically: false, encoding: .utf8)
    }
    #endif
}
