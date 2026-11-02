#if os(macOS)
import AppKit
import XCTest
@testable import JetlineApp

@MainActor
final class TabFocusTests: XCTestCase {
    func testFindsTheComposerAnywhereUnderTheRoot() {
        let root = NSView()
        let column = NSView()
        let composer = ComposerNSTextView()
        root.addSubview(NSTextView())
        root.addSubview(column)
        column.addSubview(composer)
        XCTAssertTrue(TabFocus.firstDescendant(of: ComposerNSTextView.self, in: root) === composer)
    }

    func testNoComposerNoTarget() {
        let root = NSView()
        root.addSubview(NSTextView())
        XCTAssertNil(TabFocus.firstDescendant(of: ComposerNSTextView.self, in: root))
    }

    func testChatTabTargetsItsWindowsComposer() {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: true)
        let composer = ComposerNSTextView()
        window.contentView?.addSubview(composer)
        XCTAssertTrue(TabFocus.target(for: .chat("c1"), session: { _ in nil }, in: window) === composer)
        XCTAssertNil(TabFocus.target(for: .session("s1"), session: { _ in nil }, in: window), "no such session")
        XCTAssertNil(TabFocus.target(for: nil, session: { _ in nil }, in: window))
    }
}
#endif
