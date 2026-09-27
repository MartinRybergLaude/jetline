#if os(macOS)
import XCTest
import AppKit
import SwiftUI
@testable import JetlineApp

/// Renders the diff text view offscreen. Set DIFF_RENDER_OUT to a PNG path
/// to look at the result.
@MainActor
final class DiffTextViewRenderTests: XCTestCase {
    func testLaysOutTextAndGutter() throws {
        let source = (0..<200).map { "let value\($0) = \"line \($0)\" // comment" }
        let file = FileDiff(path: "a.swift", status: .modified, additions: 1, deletions: 1, hunks: [
            .init(header: "@@ -1,200 +1,200 @@", lines: source.enumerated().flatMap { i, text -> [FileDiff.Line] in
                i == 50 ? [.init(kind: .deletion, text: text), .init(kind: .addition, text: text + " changed")]
                        : [.init(kind: .context, text: text)]
            })
        ])
        let lines = FileDiffLine.lines(for: file, language: .swift)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let container = DiffContainerView(frame: window.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(container)
        let scrollView = container.scrollView
        container.apply(lines, scrollToFirstChange: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView!.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertGreaterThan(textView.frame.width, 300)
        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0, "scrolled to first change")

        if let out = ProcessInfo.processInfo.environment["DIFF_RENDER_OUT"] {
            let view = window.contentView!
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))

            // After a scroll, the gutter must follow the text.
            textView.scroll(NSPoint(x: 0, y: 1234))
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let scrolled = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: scrolled)
            try scrolled.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: out + ".scrolled.png"))
        }
    }

    /// In a toolbar window the view sits below other content (the tab strip
    /// in the app); it must not inset itself for the titlebar or draw above
    /// its own frame.
    func testStaysInsideItsFrameUnderAToolbar() throws {
        let file = FileDiff(path: "a.swift", status: .modified, additions: 1, deletions: 0, hunks: [
            .init(header: "@@ -1,1 +1,2 @@", lines: [
                .init(kind: .context, text: "let a = 1"), .init(kind: .addition, text: "let b = 2"),
            ])
        ])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "t")
        let content = window.contentView!
        let marker = NSBox(frame: NSRect(x: 0, y: 300, width: 600, height: 100))
        marker.boxType = .custom
        marker.fillColor = .systemBlue
        content.addSubview(marker)
        let container = DiffContainerView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        content.addSubview(container)
        container.apply(FileDiffLine.lines(for: file, language: .swift), scrollToFirstChange: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        content.layoutSubtreeIfNeeded()

        XCTAssertEqual(container.scrollView.contentInsets.top, 0)
        if let out = ProcessInfo.processInfo.environment["DIFF_RENDER_OUT"] {
            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: out + ".toolbar.png"))
        }
    }

    /// Hosted in SwiftUI under a header, as in the diff tab: the header must
    /// stay on screen and the text must start right below it.
    func testHostedUnderHeaderKeepsHeaderVisible() throws {
        let file = FileDiff(path: "a.swift", status: .modified, additions: 1, deletions: 0, hunks: [
            .init(header: "@@ -1,1 +1,2 @@", lines: (0..<300).map { .init(kind: $0 == 5 ? .addition : .context, text: "let a\($0) = 1") })
        ])
        let lines = FileDiffLine.lines(for: file, language: .swift)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.toolbar = NSToolbar(identifier: "t")
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            Color.blue.frame(height: 65)
            DiffTextView(lines: lines)
        })
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        let container = try XCTUnwrap(host.firstSubview(of: DiffContainerView.self))
        let frameInHost = container.convert(container.bounds, to: host)
        XCTAssertEqual(frameInHost.height, 400 - 65 - host.safeAreaInsets.top, accuracy: 1)
        XCTAssertEqual(container.scrollView.contentInsets.top, 0)
        if let out = ProcessInfo.processInfo.environment["DIFF_RENDER_OUT"] {
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: out + ".hosted.png"))
        }
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for sub in subviews {
            if let match = sub as? T ?? sub.firstSubview(of: type) { return match }
        }
        return nil
    }
}
#endif
