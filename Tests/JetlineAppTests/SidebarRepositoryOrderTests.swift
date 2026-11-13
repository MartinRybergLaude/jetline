import XCTest
@testable import JetlineApp

final class SidebarRepositoryOrderTests: XCTestCase {
    private lazy var entries = SidebarRepositoryOrder.entries(
        [
            (id: "local", repositories: [repo("a"), repo("b")]),
            (id: "empty", repositories: []),
            (id: "remote", repositories: [repo("c"), repo("d"), repo("e")]),
        ],
        grouped: true
    )

    func testEntriesKeepAPlaceholderForAnEmptyMachineWhenGrouped() {
        XCTAssertEqual(entries.map(\.id), ["local|a", "local|b", "empty|", "remote|c", "remote|d", "remote|e"])
        XCTAssertEqual(entries.map(\.isFirstOfHost), [true, false, true, true, false, false])
    }

    func testEntriesDropTheEmptyMachineWhenNotGrouped() {
        let flat = SidebarRepositoryOrder.entries([(id: "local", repositories: [])], grouped: false)
        XCTAssertTrue(flat.isEmpty)
    }

    func testMoveWithinAMachineIsRelativeToThatMachine() {
        XCTAssertEqual(
            SidebarRepositoryOrder.move(in: entries, from: [5], to: 3),
            SidebarRepositoryMove(hostId: "remote", offsets: [2], destination: 0)
        )
        XCTAssertEqual(
            SidebarRepositoryOrder.move(in: entries, from: [0], to: 2),
            SidebarRepositoryMove(hostId: "local", offsets: [0], destination: 2)
        )
    }

    func testMoveAcrossMachinesIsRejected() {
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [4], to: 0))
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [0], to: 5))
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [1, 3], to: 0))
    }

    func testMovingAPlaceholderIsRejected() {
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [2], to: 0))
    }

    func testOutOfRangeMoveIsRejected() {
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [6], to: 0))
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [0], to: 7))
        XCTAssertNil(SidebarRepositoryOrder.move(in: entries, from: [], to: 0))
    }

    private func repo(_ id: String) -> Repository {
        Repository(id: id, name: id, path: "/tmp/\(id)", defaultBranch: "main", createdAt: Date(timeIntervalSince1970: 0))
    }
}
