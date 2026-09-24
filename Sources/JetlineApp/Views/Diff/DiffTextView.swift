import AppKit
import SwiftUI

/// Body of a diff tab: the whole file in one read-only `NSTextView`, changed
/// lines tinted full-width, line numbers in a gutter beside it.
///
/// AppKit rather than SwiftUI for scrolling: a `LazyVStack` of one
/// selectable `Text` per line re-measured every row that scrolled into view,
/// and stuttered on any file of real length. TextKit 1 with non-contiguous
/// layout only lays out what's on screen, and the gutter draws just the
/// visible rows. Lines don't wrap — the view scrolls horizontally, as an
/// editor does.
struct DiffTextView: NSViewRepresentable {
    let lines: [FileDiffLine]

    final class Coordinator {
        var lines: [FileDiffLine]?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DiffContainerView {
        DiffContainerView()
    }

    func updateNSView(_ container: DiffContainerView, context: Context) {
        guard context.coordinator.lines != lines else { return }
        let isFirstLoad = context.coordinator.lines == nil
        context.coordinator.lines = lines
        container.apply(lines, scrollToFirstChange: isFirstLoad)
    }
}

/// Gutter and scrolling text side by side. The gutter is a sibling of the
/// scroll view rather than its `verticalRulerView`: on macOS 26 a scroll view
/// with a vertical ruler stops drawing its document view altogether.
final class DiffContainerView: NSView {
    let scrollView: NSScrollView
    let textView: DiffNSTextView
    private let gutter: DiffGutterView

    override init(frame: NSRect) {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        // Hosted below the tab strip, never under the titlebar: the automatic
        // insets would still pad the top by the toolbar's height.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()

        // An explicit TextKit 1 stack with an unbounded container: lines
        // don't wrap, and the view grows to fit the longest one.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = DiffNSTextView(
            frame: NSRect(origin: .zero, size: scrollView.contentSize),
            textContainer: container
        )
        textView.configure()
        scrollView.documentView = textView
        self.textView = textView
        gutter = DiffGutterView(scrollView: scrollView, textView: textView)

        super.init(frame: frame)
        // Views don't clip by default since macOS 14, and the scroll view's
        // backdrop would otherwise paint over the tab strip above it.
        clipsToBounds = true
        addSubview(gutter)
        addSubview(scrollView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let width = gutter.thickness
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
    }

    func apply(_ lines: [FileDiffLine], scrollToFirstChange: Bool) {
        // A reload (the file changed on disk) keeps the reader's place.
        let origin = scrollView.contentView.bounds.origin
        textView.setLines(lines)
        gutter.linesDidChange()
        needsLayout = true
        if scrollToFirstChange {
            // Wait for the scroll view's first layout, so the jump has a real
            // viewport height to place the change in.
            DispatchQueue.main.async { [textView] in textView.scrollToFirstChange() }
        } else {
            textView.scroll(origin)
        }
    }
}

/// Colors and metrics shared by the text view and its gutter.
@MainActor
private enum DiffStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let lineHeight: CGFloat = 17

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        return style
    }()

    /// Fixed line height puts the slack above the glyphs; lift them to the
    /// middle of the row.
    static let baselineOffset: CGFloat = {
        (lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2
    }()

    static func background(_ line: FileDiffLine) -> NSColor? {
        line.isHunkHeader ? DiffLineTint.headerBackgroundColor : DiffLineTint.backgroundColor(line.kind)
    }

    static func marker(_ kind: FileDiff.Line.Kind) -> (String, NSColor)? {
        guard let color = DiffLineTint.markerColor(kind) else { return nil }
        return (kind == .addition ? "+" : "−", color)
    }

    static let gutterTextHeight = NSLayoutManager().defaultLineHeight(for: gutterFont)
}

final class DiffNSTextView: NSTextView {
    private(set) var lines: [FileDiffLine] = []
    /// UTF-16 offset of each line's first character, for mapping a laid-out
    /// fragment back to its row.
    private var lineStarts: [Int] = []

    func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 4, height: 6)

        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
    }

    func setLines(_ lines: [FileDiffLine]) {
        self.lines = lines
        lineStarts.removeAll(keepingCapacity: true)

        // Build the plain string first and color ranges after: one big
        // string plus attribute runs is far cheaper than appending thousands
        // of small attributed strings.
        var string = ""
        var colored: [(NSRange, NSColor)] = []
        var offset = 0
        for (index, line) in lines.enumerated() {
            lineStarts.append(offset)
            if line.isHunkHeader {
                let length = line.text.utf16.count
                colored.append((NSRange(location: offset, length: length), .secondaryLabelColor))
                string += line.text
                offset += length
            } else if let segments = line.segments {
                for segment in segments {
                    let length = segment.text.utf16.count
                    if let kind = segment.kind {
                        colored.append((NSRange(location: offset, length: length), SyntaxTheme.color(kind)))
                    }
                    string += segment.text
                    offset += length
                }
            } else {
                string += line.text
                offset += line.text.utf16.count
            }
            if index < lines.count - 1 {
                string += "\n"
                offset += 1
            }
        }

        let text = NSMutableAttributedString(string: string, attributes: [
            .font: DiffStyle.font,
            .foregroundColor: NSColor.textColor,
            .paragraphStyle: DiffStyle.paragraph,
            .baselineOffset: DiffStyle.baselineOffset,
        ])
        for (range, color) in colored {
            text.addAttribute(.foregroundColor, value: color, range: range)
        }
        textStorage?.setAttributedString(text)
    }

    func lineIndex(forCharacter char: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= char { low = mid } else { high = mid - 1 }
        }
        return max(0, low)
    }

    /// Calls `body` with each visible row's line and its rect in this view's
    /// coordinates.
    func enumerateVisibleLines(in rect: NSRect, _ body: (FileDiffLine, NSRect) -> Void) {
        guard !lines.isEmpty, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let glyphs = layoutManager.glyphRange(
            forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y),
            in: textContainer
        )
        withoutActuallyEscaping(body) { body in
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
                let char = layoutManager.characterIndexForGlyph(at: glyphRange.location)
                body(self.lines[self.lineIndex(forCharacter: char)],
                     fragment.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        enumerateVisibleLines(in: rect) { line, lineRect in
            guard let color = DiffStyle.background(line) else { return }
            color.setFill()
            NSRect(x: rect.minX, y: lineRect.minY, width: rect.width, height: lineRect.height).fill()
        }
    }

    /// Scroll so the first changed line sits a quarter of the way down.
    func scrollToFirstChange() {
        guard let index = lines.firstIndex(where: { !$0.isHunkHeader && $0.kind != .context }),
              let layoutManager, let textContainer,
              let clip = enclosingScrollView?.contentView else { return }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: lineStarts[index], length: 0),
            actualCharacterRange: nil
        )
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let y = rect.minY + textContainerOrigin.y - clip.bounds.height * 0.25
        scroll(NSPoint(x: 0, y: max(0, y)))
    }
}

/// Line numbers and the +/− marker, drawn for the visible rows only. One
/// column, as in an editor: the new file's numbers, with deleted lines — which
/// the new file doesn't have — left unnumbered.
/// Outside the scroll view, so it stays put while the text scrolls
/// horizontally.
final class DiffGutterView: NSView {
    private weak var textView: DiffNSTextView?
    private var digits = 3

    private static let padding: CGFloat = 8
    private static let markerWidth: CGFloat = 14
    private static let digitWidth: CGFloat = {
        ("0" as NSString).size(withAttributes: [.font: DiffStyle.gutterFont]).width
    }()

    init(scrollView: NSScrollView, textView: DiffNSTextView) {
        self.textView = textView
        super.init(frame: .zero)

        // The numbers must track the text frame for frame.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func needsRedraw() { needsDisplay = true }

    func linesDidChange() {
        let maxNumber = textView?.lines.compactMap(\.newNumber).max() ?? 0
        digits = max(3, String(maxNumber).count)
        needsDisplay = true
    }

    private var columnWidth: CGFloat { CGFloat(digits) * Self.digitWidth }

    var thickness: CGFloat {
        (Self.padding + columnWidth + Self.markerWidth).rounded(.up)
    }

    override func draw(_ rect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        rect.fill()
        guard let textView else { return }

        let offset = convert(NSPoint.zero, from: textView).y
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: DiffStyle.gutterFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let textHeight = DiffStyle.gutterTextHeight
        let numberRight = Self.padding + columnWidth

        textView.enumerateVisibleLines(in: textView.visibleRect) { line, lineRect in
            let row = NSRect(x: 0, y: lineRect.minY + offset, width: bounds.width, height: lineRect.height)
            guard row.intersects(rect) else { return }
            if let color = DiffStyle.background(line) {
                color.setFill()
                row.fill()
            }
            guard !line.isHunkHeader else { return }
            let y = row.minY + (row.height - textHeight) / 2
            if let number = line.newNumber {
                let s = String(number) as NSString
                s.draw(at: NSPoint(x: numberRight - s.size(withAttributes: numberAttributes).width, y: y),
                       withAttributes: numberAttributes)
            }
            if let (marker, color) = DiffStyle.marker(line.kind) {
                (marker as NSString).draw(
                    at: NSPoint(x: numberRight + 4, y: y),
                    withAttributes: [.font: DiffStyle.gutterFont, .foregroundColor: color]
                )
            }
        }

        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
}
