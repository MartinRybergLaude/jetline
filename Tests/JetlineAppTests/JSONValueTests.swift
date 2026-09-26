import XCTest
@testable import JetlineApp

final class JSONValueTests: XCTestCase {
    func testIntFromDoubleOnlyWhenExact() {
        XCTAssertEqual(JSONValue.double(42).int, 42)
        XCTAssertNil(JSONValue.double(1.5).int)
        // Out of Int's range: nil rather than a trap.
        XCTAssertNil(JSONValue.double(1e20).int)
        XCTAssertNil(JSONValue.double(.infinity).int)
        XCTAssertNil(JSONValue.double(.nan).int)
    }
}
