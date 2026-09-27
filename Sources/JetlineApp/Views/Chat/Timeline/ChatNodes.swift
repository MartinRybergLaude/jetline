#if os(macOS)
import AppKit
import Quartz

// The chat timeline is plain AppKit, laid out by hand. Each row's content is
// described as a tree of nodes. A node measures itself at a width (memoized,
// so a row's height is exact and computed once per width) and mounts onto
// views that are recycled by type when the table reuses a row.

/// How far a node may draw past its own leading and trailing edges. Rows
/// are wider than the reading column, and wide tables grow into the space
/// beside it.
struct ChatBreakout: Equatable {
    var leading: CGFloat = 0
    var trailing: CGFloat = 0
}

struct ChatChildFrame {
    var rect: CGRect
    var breakout = ChatBreakout()
}

@MainActor
class ChatNode {
    /// Stands in for "no width limit" when measuring natural size.
    static let unbounded: CGFloat = 100_000

    private var sizes: [CGFloat: CGSize] = [:]

    final func size(for width: CGFloat) -> CGSize {
        let width = max(0, width)
        if let hit = sizes[width] { return hit }
        if sizes.count > 6 { sizes.removeAll(keepingCapacity: true) }
        let size = measure(width)
        sizes[width] = size
        return size
    }

    /// Size at `width`. Content that hugs may come back narrower.
    func measure(_ width: CGFloat) -> CGSize { CGSize(width: width, height: 0) }
    /// Mounting reuses an existing view when it is exactly this class.
    var viewType: NSView.Type { ChatContainerView.self }
    func makeView() -> NSView { ChatContainerView() }
    func configure(_ view: NSView, size: CGSize) {}
    var children: [ChatNode] { [] }
    /// Frames of `children`, in the coordinates of the container's child host.
    func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] { [] }
}

/// A view that hosts the views of a node's children.
@MainActor
protocol ChatContainer: NSView {
    var mounted: [NSView] { get set }
    var childHost: NSView { get }
    func didMount()
}

@MainActor
enum ChatMount {
    @discardableResult
    static func mount(_ node: ChatNode, reusing old: NSView?, frame: CGRect, breakout: ChatBreakout) -> NSView {
        let view: NSView
        if let old, ObjectIdentifier(type(of: old)) == ObjectIdentifier(node.viewType) {
            view = old
        } else {
            view = node.makeView()
        }
        if view.frame != frame { view.frame = frame }
        node.configure(view, size: frame.size)
        if let container = view as? ChatContainer {
            mountChildren(of: node, in: container, size: frame.size, breakout: breakout)
        }
        return view
    }

    static func mountChildren(of node: ChatNode, in container: ChatContainer, size: CGSize, breakout: ChatBreakout) {
        let kids = node.children
        let frames = node.layout(size, breakout: breakout)
        var views: [NSView] = []
        views.reserveCapacity(kids.count)
        for (index, kid) in kids.enumerated() {
            let old = index < container.mounted.count ? container.mounted[index] : nil
            views.append(mount(kid, reusing: old, frame: frames[index].rect, breakout: frames[index].breakout))
        }
        let host = container.childHost
        for old in container.mounted where !views.contains(where: { $0 === old }) {
            old.removeFromSuperview()
        }
        for view in views where view.superview !== host {
            host.addSubview(view)
        }
        container.mounted = views
        container.didMount()
    }
}

@MainActor
enum ChatHitTest {
    /// Like `NSView.hitTest`, but children drawn outside the view's bounds
    /// (a broken-out table, a hover bar in the gap below a message) still
    /// get the click.
    static func hit(_ view: NSView, _ point: NSPoint) -> NSView? {
        guard !view.isHidden, view.alphaValue > 0.01 else { return nil }
        let local = view.superview.map { view.convert(point, from: $0) } ?? point
        for sub in view.subviews.reversed() {
            if let hit = sub.hitTest(local) { return hit }
        }
        return view.bounds.contains(local) ? view : nil
    }
}

// MARK: - Container

/// Flipped, layer-backed box: fill, border and corner radius, no drawing.
class ChatContainerView: NSView, ChatContainer {
    var mounted: [NSView] = []
    var childHost: NSView { self }

    var fill: NSColor?
    var border: NSColor?
    var borderWidth: CGFloat = 0
    var cornerRadius: CGFloat = 0
    var clipsContent = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    func setStyle(fill: NSColor?, border: NSColor? = nil, borderWidth: CGFloat = 0, cornerRadius: CGFloat = 0, clips: Bool = false) {
        guard fill != self.fill || border != self.border || borderWidth != self.borderWidth
            || cornerRadius != self.cornerRadius || clips != clipsContent else { return }
        self.fill = fill
        self.border = border
        self.borderWidth = borderWidth
        self.cornerRadius = cornerRadius
        clipsContent = clips
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fill?.cgColor
        layer.borderColor = border?.cgColor
        layer.borderWidth = border == nil ? 0 : borderWidth
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = clipsContent
    }

    override func hitTest(_ point: NSPoint) -> NSView? { ChatHitTest.hit(self, point) }

    func didMount() {}
}

// MARK: - Text

extension NSAttributedString.Key {
    /// `[CGFloat]`: x positions of block-quote bars beside a paragraph.
    static let chatQuoteBars = NSAttributedString.Key("jetline.chatQuoteBars")
    /// `NSColor` filled behind a whole line, edge to edge (diff lines).
    static let chatLineTint = NSAttributedString.Key("jetline.chatLineTint")
}

/// Measures text exactly as `ChatTextView` lays it out: TextKit 1, no line
/// fragment padding, no insets.
@MainActor
enum ChatTextMeasure {
    private final class Stack {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)

        init() {
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
        }
    }

    private static let stack = Stack()

    static func size(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        guard string.length > 0 else { return .zero }
        stack.container.size = NSSize(width: width, height: ChatNode.unbounded)
        stack.storage.setAttributedString(string)
        stack.layoutManager.ensureLayout(for: stack.container)
        let used = stack.layoutManager.usedRect(for: stack.container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}

/// Read-only, selectable text. TextKit 1 so layout matches `ChatTextMeasure`.
final class ChatTextView: NSTextView {
    private var content: NSAttributedString?
    private var wraps = true
    private var hasQuoteBars = false
    private var hasLineTints = false

    static func make() -> ChatTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: ChatNode.unbounded))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        let view = ChatTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        view.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    func setContent(_ string: NSAttributedString, wraps: Bool) {
        if self.wraps != wraps {
            self.wraps = wraps
            updateContainer()
        }
        guard string !== content else { return }
        content = string
        textStorage?.setAttributedString(string)
        let full = NSRange(location: 0, length: string.length)
        hasQuoteBars = false
        hasLineTints = false
        string.enumerateAttributes(in: full) { attributes, _, stop in
            if attributes[.chatQuoteBars] != nil { hasQuoteBars = true }
            if attributes[.chatLineTint] != nil { hasLineTints = true }
            if hasQuoteBars && hasLineTints { stop.pointee = true }
        }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateContainer()
    }

    private func updateContainer() {
        let width = wraps ? bounds.width : ChatNode.unbounded
        if textContainer?.size.width != width {
            textContainer?.size = NSSize(width: width, height: ChatNode.unbounded)
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard hasQuoteBars || hasLineTints, let storage = textStorage, let layoutManager, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        let origin = textContainerOrigin

        func extent(of range: NSRange, used: Bool) -> NSRect {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, usedRect, _, _, _ in
                box = box.union(used ? usedRect : rect)
            }
            return box
        }

        if hasLineTints {
            storage.enumerateAttribute(.chatLineTint, in: full) { value, range, _ in
                guard let color = value as? NSColor else { return }
                let box = extent(of: range, used: false)
                guard !box.isNull, box.maxY + origin.y >= rect.minY, box.minY + origin.y <= rect.maxY else { return }
                color.setFill()
                NSRect(x: bounds.minX, y: box.minY + origin.y, width: bounds.width, height: box.height).fill()
            }
        }
        if hasQuoteBars {
            let color = NSColor.secondaryLabelColor.withAlphaComponent(0.35)
            storage.enumerateAttribute(.chatQuoteBars, in: full) { value, range, _ in
                guard let bars = value as? [CGFloat], !bars.isEmpty else { return }
                let box = extent(of: range, used: true)
                guard !box.isNull else { return }
                color.setFill()
                for x in bars {
                    let bar = NSRect(x: x, y: box.minY + origin.y, width: 3, height: box.height)
                    NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
        }
    }
}

/// Wrapping selectable text, as a node.
final class TextNode: ChatNode {
    let string: NSAttributedString
    let wraps: Bool
    /// Report the text's own width rather than the proposed one.
    let hug: Bool
    /// Extra width after unwrapped text, inside the view (so line tints
    /// still reach it).
    let trailingPad: CGFloat

    init(_ string: NSAttributedString, wraps: Bool = true, hug: Bool = false, trailingPad: CGFloat = 0) {
        self.string = string
        self.wraps = wraps
        self.hug = hug
        self.trailingPad = trailingPad
    }

    override func measure(_ width: CGFloat) -> CGSize {
        if !wraps {
            let size = ChatTextMeasure.size(string, width: ChatNode.unbounded)
            return CGSize(width: size.width + trailingPad, height: size.height)
        }
        let size = ChatTextMeasure.size(string, width: width)
        return CGSize(width: hug ? min(width, size.width + 1) : width, height: size.height)
    }

    override var viewType: NSView.Type { ChatTextView.self }
    override func makeView() -> NSView { ChatTextView.make() }
    override func configure(_ view: NSView, size: CGSize) {
        (view as? ChatTextView)?.setContent(string, wraps: wraps)
    }
}

/// One line of non-selectable text, truncated to fit.
class ChatLabel: NSTextField {
    static func make() -> ChatLabel {
        let label = ChatLabel(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        return label
    }

    private static let measuring = ChatLabel.make()

    static func naturalSize(_ string: NSAttributedString) -> CGSize {
        measuring.attributedStringValue = string
        let size = measuring.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: ChatNode.unbounded, height: ChatNode.unbounded)) ?? .zero
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}

final class LabelNode: ChatNode {
    let string: NSAttributedString
    let truncation: NSLineBreakMode
    let toolTip: String?

    init(_ string: NSAttributedString, truncation: NSLineBreakMode = .byTruncatingTail, toolTip: String? = nil) {
        self.string = string
        self.truncation = truncation
        self.toolTip = toolTip
    }

    convenience init(_ text: String, font: NSFont, color: NSColor = .labelColor, truncation: NSLineBreakMode = .byTruncatingTail, toolTip: String? = nil) {
        self.init(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]), truncation: truncation, toolTip: toolTip)
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let natural = ChatLabel.naturalSize(string)
        return CGSize(width: min(width, natural.width), height: natural.height)
    }

    override var viewType: NSView.Type { ChatLabel.self }
    override func makeView() -> NSView { ChatLabel.make() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let label = view as? ChatLabel else { return }
        if label.attributedStringValue != string { label.attributedStringValue = string }
        label.lineBreakMode = truncation
        label.toolTip = toolTip
    }
}

/// A one-letter chip (a git file status). Drawn rather than built from a
/// label in a box: a text field centres its line box, which leaves a lone
/// capital sitting low in a chip this small. This centres the letter's ink.
final class LetterChipNode: ChatNode {
    let letter: String
    let font: NSFont
    let fill: NSColor
    let toolTip: String?

    static let height: CGFloat = 14

    init(_ letter: String, font: NSFont, fill: NSColor, toolTip: String? = nil) {
        self.letter = letter
        self.font = font
        self.fill = fill
        self.toolTip = toolTip
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let text = (letter as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: max(Self.height, ceil(text) + 8), height: Self.height)
    }

    override var viewType: NSView.Type { LetterChipView.self }
    override func makeView() -> NSView { LetterChipView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? LetterChipView else { return }
        view.letter = letter
        view.font = font
        view.fill = fill
        view.toolTip = toolTip
        view.needsDisplay = true
    }
}

final class LetterChipView: NSView {
    var letter = ""
    var font = NSFont.systemFont(ofSize: 9)
    var fill = NSColor.clear

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: NSColor.white])
        let ink = text.boundingRect(with: bounds.size, options: [.usesDeviceMetrics])
        // Without `.usesLineFragmentOrigin` the rect's origin is the
        // baseline; place it so the glyph's own bounds sit mid-chip.
        // (Unflipped, so the ink rect's y runs up from the baseline.)
        let origin = NSPoint(x: bounds.midX - ink.midX, y: bounds.midY - ink.midY)
        text.draw(with: NSRect(origin: origin, size: bounds.size), options: [])
    }
}

// MARK: - Images

final class ChatSymbolView: NSImageView {
    var symbolKey = ""
}

final class SymbolNode: ChatNode {
    let name: String
    let pointSize: CGFloat
    let weight: NSFont.Weight
    let color: NSColor
    let toolTip: String?

    init(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .secondaryLabelColor, toolTip: String? = nil) {
        self.name = name
        pointSize = size
        self.weight = weight
        self.color = color
        self.toolTip = toolTip
    }

    private var image: NSImage? {
        ChatSymbols.image(name, size: pointSize, weight: weight)
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let size = image?.size ?? .zero
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }

    override var viewType: NSView.Type { ChatSymbolView.self }
    override func makeView() -> NSView {
        let view = ChatSymbolView()
        view.imageScaling = .scaleNone
        return view
    }

    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatSymbolView else { return }
        let key = "\(name)|\(pointSize)|\(weight.rawValue)"
        if view.symbolKey != key {
            view.symbolKey = key
            view.image = image
        }
        view.contentTintColor = color
        view.toolTip = toolTip
    }
}

@MainActor
enum ChatSymbols {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight))
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

final class ChatSpinner: NSProgressIndicator {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { startAnimation(nil) } else { stopAnimation(nil) }
    }
}

final class SpinnerNode: ChatNode {
    let diameter: CGFloat

    init(diameter: CGFloat) { self.diameter = diameter }

    override func measure(_ width: CGFloat) -> CGSize { CGSize(width: diameter, height: diameter) }
    override var viewType: NSView.Type { ChatSpinner.self }
    override func makeView() -> NSView {
        let spinner = ChatSpinner()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        return spinner
    }

    override func configure(_ view: NSView, size: CGSize) {
        guard let spinner = view as? ChatSpinner else { return }
        spinner.controlSize = diameter <= 12 ? .mini : .small
        if spinner.window != nil { spinner.startAnimation(nil) }
    }
}

/// A spinning, breathing asterisk: the working indicator.
final class ChatSparkView: NSView {
    var color: NSColor = .controlAccentColor {
        didSet { if color != oldValue { updateLayer() } }
    }
    var isAnimating = true {
        didSet { if isAnimating != oldValue { animate() } }
    }
    private let shape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.lineCap = .round
        shape.fillColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shape.strokeColor = color.cgColor
        }
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shape.lineWidth = max(1.5, side * 0.15)
        let path = CGMutablePath()
        let center = CGPoint(x: side / 2, y: side / 2)
        let outer = side / 2 - shape.lineWidth / 2
        for ray in 0..<8 {
            let angle = CGFloat(ray) * .pi / 4
            // Alternate ray lengths, like a hand-drawn spark.
            let length = outer * (ray.isMultiple(of: 2) ? 1 : 0.72)
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length))
        }
        shape.path = path
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func animate() {
        shape.removeAllAnimations()
        guard window != nil, isAnimating else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * CGFloat.pi
        spin.duration = 3
        spin.repeatCount = .infinity
        shape.add(spin, forKey: "spin")
        let breathe = CABasicAnimation(keyPath: "transform.scale")
        breathe.fromValue = 1
        breathe.toValue = 0.78
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shape.add(breathe, forKey: "breathe")
    }
}

final class SparkNode: ChatNode {
    let side: CGFloat
    let color: NSColor
    let animating: Bool

    init(side: CGFloat, color: NSColor, animating: Bool) {
        self.side = side
        self.color = color
        self.animating = animating
    }

    override func measure(_ width: CGFloat) -> CGSize { CGSize(width: side, height: side) }
    override var viewType: NSView.Type { ChatSparkView.self }
    override func makeView() -> NSView { ChatSparkView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatSparkView else { return }
        view.color = color
        view.isAnimating = animating
    }
}

/// Image file in a rounded, outlined frame. A click opens it, and the
/// images beside it, in Quick Look.
final class ChatThumbView: ChatContainerView, @preconcurrency QLPreviewPanelDataSource {
    var path = ""
    /// The message's images, for paging in Quick Look.
    var gallery: [String] = []

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = gallery.firstIndex(of: path) ?? 0
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Space toggles the preview, as in Finder.
        guard event.charactersIgnoringModifiers == " ", let panel = QLPreviewPanel.shared() else {
            super.keyDown(with: event)
            return
        }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.currentPreviewItemIndex = gallery.firstIndex(of: path) ?? 0
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { gallery.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        URL(fileURLWithPath: gallery[index]) as NSURL
    }
}

final class ThumbNode: ChatNode {
    let path: String
    let gallery: [String]
    /// The longest side; the image keeps its aspect ratio within it.
    let maxSide: CGFloat

    init(path: String, gallery: [String], maxSide: CGFloat) {
        self.path = path
        self.gallery = gallery
        self.maxSide = maxSide
    }

    private static let cache = NSCache<NSString, NSImage>()

    private var image: NSImage? {
        if let hit = Self.cache.object(forKey: path as NSString) { return hit }
        guard let image = NSImage(contentsOfFile: EngineFiles.localPath(for: path)) else { return nil }
        Self.cache.setObject(image, forKey: path as NSString)
        return image
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let limit = min(maxSide, width)
        guard let image, image.size.width > 0, image.size.height > 0 else { return CGSize(width: limit, height: limit) }
        let scale = limit / max(image.size.width, image.size.height)
        // Very thin images still get a clickable frame.
        return CGSize(width: max(48, (image.size.width * scale).rounded()), height: max(48, (image.size.height * scale).rounded()))
    }

    override var viewType: NSView.Type { ChatThumbView.self }
    override func makeView() -> NSView { ChatThumbView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatThumbView else { return }
        view.setStyle(fill: .quaternaryLabelColor, border: NSColor.secondaryLabelColor.withAlphaComponent(0.25), borderWidth: 0.5, cornerRadius: 8, clips: true)
        view.gallery = gallery
        guard view.path != path else { return }
        view.path = path
        view.layer?.contents = image
        view.layer?.contentsGravity = .resizeAspectFill
        view.toolTip = (path as NSString).lastPathComponent
    }
}

// MARK: - Layout nodes

/// Empty space, optionally a filled rule.
final class FillNode: ChatNode {
    let height: CGFloat
    let color: NSColor?

    init(height: CGFloat = 0, color: NSColor? = nil) {
        self.height = height
        self.color = color
    }

    override func measure(_ width: CGFloat) -> CGSize { CGSize(width: width, height: height) }
    override func configure(_ view: NSView, size: CGSize) {
        (view as? ChatContainerView)?.setStyle(fill: color)
    }
}

final class VStackNode: ChatNode {
    enum Align { case fill, leading, trailing }

    private let items: [ChatNode]
    /// Space above each item; the first entry is ignored.
    private let gaps: [CGFloat]
    private let align: Align

    init(_ items: [ChatNode], spacing: CGFloat = 0, align: Align = .fill) {
        self.items = items
        gaps = Array(repeating: spacing, count: items.count)
        self.align = align
    }

    init(spaced: [(ChatNode, CGFloat)], align: Align = .fill) {
        items = spaced.map(\.0)
        gaps = spaced.map(\.1)
        self.align = align
    }

    override var children: [ChatNode] { items }

    override func measure(_ width: CGFloat) -> CGSize {
        var height: CGFloat = 0
        var widest: CGFloat = 0
        for (index, item) in items.enumerated() {
            let size = item.size(for: width)
            if index > 0 { height += gaps[index] }
            height += size.height
            widest = max(widest, size.width)
        }
        return CGSize(width: align == .fill ? width : min(width, widest), height: height)
    }

    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        var y: CGFloat = 0
        return items.enumerated().map { index, item in
            if index > 0 { y += gaps[index] }
            let measured = item.size(for: size.width)
            let width = align == .fill ? size.width : min(size.width, measured.width)
            let x: CGFloat = align == .trailing ? size.width - width : 0
            let rect = CGRect(x: x, y: y, width: width, height: measured.height)
            y += measured.height
            return ChatChildFrame(rect: rect, breakout: ChatBreakout(
                leading: breakout.leading + x,
                trailing: breakout.trailing + size.width - x - width
            ))
        }
    }
}

final class HStackNode: ChatNode {
    enum Align { case center, top }

    private let items: [ChatNode]
    private let spacing: CGFloat
    /// Items that share the width the others leave.
    private let flexible: Set<Int>
    /// Fixed items that give up width first (truncating labels): measured
    /// after the other fixed items, in what they leave.
    private let compressible: Set<Int>
    private let align: Align

    init(_ items: [ChatNode], spacing: CGFloat, flexible: Set<Int> = [], compressible: Set<Int> = [], align: Align = .center) {
        self.items = items
        self.spacing = spacing
        self.flexible = flexible
        self.compressible = compressible
        self.align = align
    }

    override var children: [ChatNode] { items }

    private func widths(for width: CGFloat) -> [CGFloat] {
        var widths = Array(repeating: CGFloat(0), count: items.count)
        var used = spacing * CGFloat(max(0, items.count - 1))
        let fixed = items.indices.filter { !flexible.contains($0) }
        for index in fixed.filter({ !compressible.contains($0) }) + fixed.filter({ compressible.contains($0) }) {
            widths[index] = items[index].size(for: max(0, width - used)).width
            used += widths[index]
        }
        if !flexible.isEmpty {
            let each = max(0, (width - used) / CGFloat(flexible.count))
            for index in flexible { widths[index] = each }
        }
        return widths
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let widths = widths(for: width)
        var height: CGFloat = 0
        for (index, item) in items.enumerated() {
            height = max(height, item.size(for: widths[index]).height)
        }
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, items.count - 1))
        return CGSize(width: flexible.isEmpty ? min(width, total) : width, height: height)
    }

    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        let widths = widths(for: size.width)
        var x: CGFloat = 0
        return items.enumerated().map { index, item in
            let height = item.size(for: widths[index]).height
            let y = align == .center ? ((size.height - height) / 2).rounded() : 0
            let rect = CGRect(x: x, y: y, width: widths[index], height: height)
            x += widths[index] + spacing
            return ChatChildFrame(rect: rect)
        }
    }
}

/// Padding around one child, with an optional fill and border.
final class BoxNode: ChatNode {
    let child: ChatNode?
    let padding: NSEdgeInsets
    let fill: NSColor?
    let border: NSColor?
    let borderWidth: CGFloat
    let radius: CGFloat
    let hug: Bool
    let toolTip: String?
    let fixedWidth: CGFloat?
    let fixedHeight: CGFloat?

    init(
        _ child: ChatNode?,
        padding: NSEdgeInsets = NSEdgeInsets(),
        fill: NSColor? = nil,
        border: NSColor? = nil,
        borderWidth: CGFloat = 0.5,
        radius: CGFloat = 0,
        hug: Bool = false,
        toolTip: String? = nil,
        width: CGFloat? = nil,
        height: CGFloat? = nil
    ) {
        self.child = child
        self.padding = padding
        self.fill = fill
        self.border = border
        self.borderWidth = borderWidth
        self.radius = radius
        self.hug = hug
        self.toolTip = toolTip
        fixedWidth = width
        fixedHeight = height
    }

    override var children: [ChatNode] { child.map { [$0] } ?? [] }

    override func measure(_ width: CGFloat) -> CGSize {
        let horizontal = padding.left + padding.right
        let inner = fixedWidth.map { $0 - horizontal } ?? width - horizontal
        let size = child?.size(for: max(0, inner)) ?? .zero
        let outerWidth = fixedWidth ?? (hug ? min(width, size.width + horizontal) : width)
        return CGSize(width: outerWidth, height: fixedHeight ?? size.height + padding.top + padding.bottom)
    }

    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        guard let child else { return [] }
        let width = max(0, size.width - padding.left - padding.right)
        let height: CGFloat
        let y: CGFloat
        if fixedHeight != nil {
            height = child.size(for: width).height
            y = ((size.height - height) / 2).rounded()
        } else {
            height = max(0, size.height - padding.top - padding.bottom)
            y = padding.top
        }
        return [ChatChildFrame(
            rect: CGRect(x: padding.left, y: y, width: width, height: height),
            breakout: ChatBreakout(leading: breakout.leading + padding.left, trailing: breakout.trailing + padding.right)
        )]
    }

    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatContainerView else { return }
        view.setStyle(fill: fill, border: border, borderWidth: borderWidth, cornerRadius: radius, clips: false)
        view.toolTip = toolTip
    }
}

extension NSEdgeInsets {
    init(h: CGFloat = 0, v: CGFloat = 0) {
        self.init(top: v, left: h, bottom: v, right: h)
    }
}

// MARK: - Horizontal scrolling

/// Scrolls sideways only. Vertical gestures go to the timeline, locked per
/// gesture so a diagonal swipe doesn't do both.
final class ChatHScrollView: NSScrollView, ChatContainer {
    var mounted: [NSView] = []
    var childHost: NSView { documentView ?? contentView }
    private var axisDecided = false
    private var forwarding = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = false
        hasHorizontalScroller = false
        verticalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets()
        documentView = ChatContainerView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func didMount() {}

    private var canScroll: Bool {
        (documentView?.frame.width ?? 0) > contentView.bounds.width + 0.5
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began || event.phase == .mayBegin {
            axisDecided = false
        }
        let discrete = event.phase == [] && event.momentumPhase == []
        if discrete || !axisDecided, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            forwarding = !canScroll || abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX)
            axisDecided = true
        }
        if forwarding || !canScroll {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class HScrollNode: ChatNode {
    let child: ChatNode
    /// Space before and after the content, inside the scroller.
    let margin: CGFloat
    /// Stretch the content to the visible width when it is narrower.
    let fillViewport: Bool

    init(_ child: ChatNode, margin: CGFloat = 0, fillViewport: Bool = false) {
        self.child = child
        self.margin = margin
        self.fillViewport = fillViewport
    }

    var naturalWidth: CGFloat { child.size(for: ChatNode.unbounded).width }

    override var children: [ChatNode] { [child] }

    override func measure(_ width: CGFloat) -> CGSize {
        CGSize(width: width, height: child.size(for: ChatNode.unbounded).height)
    }

    override var viewType: NSView.Type { ChatHScrollView.self }
    override func makeView() -> NSView { ChatHScrollView() }

    override func configure(_ view: NSView, size: CGSize) {
        guard let scroll = view as? ChatHScrollView else { return }
        let docSize = NSSize(width: max(naturalWidth + margin * 2, size.width), height: size.height)
        if scroll.documentView?.frame.size != docSize {
            scroll.documentView?.setFrameSize(docSize)
        }
    }

    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        let natural = child.size(for: ChatNode.unbounded)
        let width = fillViewport ? max(natural.width, size.width - margin * 2) : natural.width
        return [ChatChildFrame(rect: CGRect(x: margin, y: 0, width: width, height: natural.height))]
    }
}

// MARK: - Interaction

/// Plain button: the whole area is the target, no chrome.
final class ChatClickView: ChatContainerView {
    var action: (() -> Void)?
    var isEnabled = true
    var pointingCursor = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
    }

    override func resetCursorRects() {
        if pointingCursor && isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Text that reads as live: full strength with a light sweeping across
/// while `isLive`, dimmed once done, full strength again under the pointer.
final class ChatGlowView: ChatContainerView {
    var isLive = false {
        didSet { if isLive != oldValue { apply() } }
    }
    private var hovering = false
    private var area: NSTrackingArea?
    private let shimmer = CAGradientLayer()
    static let dimmed: CGFloat = 0.5

    override init(frame: NSRect) {
        super.init(frame: frame)
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.colors = [0.4, 0.4, 1, 0.4, 0.4].map { NSColor(white: 1, alpha: $0).cgColor }
        shimmer.locations = [0, 0.35, 0.5, 0.65, 1]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; apply() }
    override func mouseExited(with event: NSEvent) { hovering = false; apply() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Three widths, so the bright band enters and leaves fully.
        shimmer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3, height: bounds.height)
        CATransaction.commit()
        if isLive { startShimmer() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        alphaValue = isLive || hovering ? 1 : Self.dimmed
        if isLive && window != nil {
            layer?.mask = shimmer
            startShimmer()
        } else {
            shimmer.removeAllAnimations()
            layer?.mask = nil
        }
    }

    private func startShimmer() {
        guard window != nil, bounds.width > 0 else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bounds.width / 2
        sweep.toValue = bounds.width * 1.5
        sweep.duration = max(1.2, Double(bounds.width) / 110)
        sweep.repeatCount = .infinity
        shimmer.add(sweep, forKey: "sweep")
    }
}

final class GlowNode: ChatNode {
    let child: ChatNode
    let live: Bool

    init(_ child: ChatNode, live: Bool) {
        self.child = child
        self.live = live
    }

    override var children: [ChatNode] { [child] }
    override func measure(_ width: CGFloat) -> CGSize { child.size(for: width) }
    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        [ChatChildFrame(rect: CGRect(origin: .zero, size: size), breakout: breakout)]
    }

    override var viewType: NSView.Type { ChatGlowView.self }
    override func makeView() -> NSView { ChatGlowView() }
    override func configure(_ view: NSView, size: CGSize) {
        (view as? ChatGlowView)?.isLive = live
    }
}

final class ClickNode: ChatNode {
    let child: ChatNode
    let enabled: Bool
    let pointingCursor: Bool
    let action: () -> Void

    init(_ child: ChatNode, enabled: Bool = true, pointingCursor: Bool = false, action: @escaping () -> Void) {
        self.child = child
        self.enabled = enabled
        self.pointingCursor = pointingCursor
        self.action = action
    }

    override var children: [ChatNode] { [child] }
    override func measure(_ width: CGFloat) -> CGSize { child.size(for: width) }
    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        [ChatChildFrame(rect: CGRect(origin: .zero, size: size), breakout: breakout)]
    }

    override var viewType: NSView.Type { ChatClickView.self }
    override func makeView() -> NSView { ChatClickView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatClickView else { return }
        view.setStyle(fill: nil)
        view.action = action
        if view.isEnabled != enabled || view.pointingCursor != pointingCursor {
            view.isEnabled = enabled
            view.pointingCursor = pointingCursor
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

/// Shows its second child (a bar of actions) in the gap below the first
/// while the pointer is over either. The bar is part of this view, so
/// moving onto it doesn't read as leaving the message.
final class ChatHoverView: ChatContainerView {
    var isEnabled = true
    /// Shows the bar regardless of hover.
    var isPinned = false
    private var hovering = false
    private var area: NSTrackingArea?

    private var bar: NSView? { mounted.count > 1 ? mounted[1] : nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        self.area = area
        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            setHovering(bounds.contains(point), animated: false)
        }
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true, animated: true) }
    override func mouseExited(with event: NSEvent) { setHovering(false, animated: true) }

    override func didMount() { applyBar(animated: false) }

    private func setHovering(_ value: Bool, animated: Bool) {
        guard value != hovering else { return }
        hovering = value
        applyBar(animated: animated)
    }

    private func applyBar(animated: Bool) {
        guard let bar else { return }
        let alpha: CGFloat = isEnabled && (hovering || isPinned) ? 1 : 0
        guard bar.alphaValue != alpha else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                bar.animator().alphaValue = alpha
            }
        } else {
            bar.alphaValue = alpha
        }
    }
}

final class HoverNode: ChatNode {
    enum Edge { case leading, trailing }

    let content: ChatNode
    let bar: ChatNode
    let edge: Edge
    let gap: CGFloat
    let enabled: Bool
    let pinned: Bool
    static let barHeight: CGFloat = 24

    init(_ content: ChatNode, bar: ChatNode, edge: Edge, gap: CGFloat, enabled: Bool, pinned: Bool = false) {
        self.content = content
        self.bar = bar
        self.edge = edge
        self.gap = gap
        self.enabled = enabled
        self.pinned = pinned
    }

    /// Height the bar adds below the content.
    var reach: CGFloat { gap + Self.barHeight }

    override var children: [ChatNode] { [content, bar] }

    override func measure(_ width: CGFloat) -> CGSize {
        let size = content.size(for: width)
        return CGSize(width: size.width, height: size.height + reach)
    }

    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        let contentHeight = content.size(for: size.width).height
        let barWidth = bar.size(for: size.width).width
        let x = edge == .leading ? 0 : size.width - barWidth
        return [
            ChatChildFrame(rect: CGRect(x: 0, y: 0, width: size.width, height: contentHeight), breakout: breakout),
            ChatChildFrame(rect: CGRect(x: x, y: contentHeight + gap, width: barWidth, height: Self.barHeight)),
        ]
    }

    override var viewType: NSView.Type { ChatHoverView.self }
    override func makeView() -> NSView { ChatHoverView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatHoverView else { return }
        view.isEnabled = enabled
        view.isPinned = pinned
    }
}

/// Borderless icon button with a rounded wash under the pointer.
final class ChatIconButton: NSView {
    private let imageView = NSImageView()
    private var symbol = ""
    private var flashing = false
    private var hovering = false
    private var pressed = false
    private var area: NSTrackingArea?
    var action: (() -> Void)?
    /// Symbol shown briefly after a click ("checkmark" after copying).
    var flashSymbol: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    func setSymbol(_ name: String) {
        guard name != symbol else { return }
        symbol = name
        guard !flashing else { return }
        imageView.image = Self.image(name)
    }

    private static func image(_ name: String) -> NSImage? {
        ChatSymbols.image(name, size: 11, weight: .medium)
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    override func updateLayer() {
        let alpha: CGFloat = pressed ? 0.25 : hovering ? 0.15 : 0
        layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(alpha).cgColor
        layer?.cornerRadius = 5
        imageView.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    private func setHovering(_ value: Bool) {
        hovering = value
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action?()
        if let flashSymbol { flash(flashSymbol) }
    }

    private func flash(_ name: String) {
        flashing = true
        if let image = Self.image(name) {
            imageView.setSymbolImage(image, contentTransition: .replace.downUp, options: .speed(3))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            flashing = false
            if let image = Self.image(symbol) {
                imageView.setSymbolImage(image, contentTransition: .replace.downUp, options: .speed(3))
            }
        }
    }
}

final class IconButtonNode: ChatNode {
    let symbol: String
    let help: String
    let flashSymbol: String?
    let action: () -> Void

    init(_ symbol: String, help: String, flashSymbol: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.flashSymbol = flashSymbol
        self.action = action
    }

    override func measure(_ width: CGFloat) -> CGSize { CGSize(width: 24, height: 24) }
    override var viewType: NSView.Type { ChatIconButton.self }
    override func makeView() -> NSView { ChatIconButton() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let button = view as? ChatIconButton else { return }
        button.setSymbol(symbol)
        button.flashSymbol = flashSymbol
        button.action = action
        button.toolTip = help
    }
}

/// "12s · Thinking…", ticking once a second.
final class ChatElapsedLabel: ChatLabel {
    var since = Date()
    /// Fixed end: the label stops ticking.
    var until: Date? {
        didSet { if until != oldValue { schedule() } }
    }
    var attributes: [NSAttributedString.Key: Any] = [:]
    var suffix = ""
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard window != nil, until == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func tick() {
        let seconds = max(0, Int((until ?? Date()).timeIntervalSince(since)))
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
        attributedStringValue = NSAttributedString(string: elapsed + suffix, attributes: attributes)
    }
}

final class ElapsedNode: ChatNode {
    let since: Date
    let until: Date?
    let suffix: String
    let attributes: [NSAttributedString.Key: Any]

    init(since: Date, until: Date? = nil, suffix: String, font: NSFont, color: NSColor) {
        self.since = since
        self.until = until
        self.suffix = suffix
        attributes = [.font: font, .foregroundColor: color]
    }

    override func measure(_ width: CGFloat) -> CGSize {
        let size = ChatLabel.naturalSize(NSAttributedString(string: "00m 00s" + suffix, attributes: attributes))
        return CGSize(width: min(width, size.width), height: size.height)
    }

    override var viewType: NSView.Type { ChatElapsedLabel.self }
    override func makeView() -> NSView {
        let label = ChatElapsedLabel(frame: .zero)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    override func configure(_ view: NSView, size: CGSize) {
        guard let label = view as? ChatElapsedLabel else { return }
        label.since = since
        label.suffix = suffix
        label.until = until
        label.attributes = attributes
        label.tick()
    }
}

/// Places a row's content in the centred reading column.
final class RowRootNode: ChatNode {
    static let columnWidth: CGFloat = 720
    static let sidePadding: CGFloat = 24

    let child: ChatNode
    /// Space below the content, to the next row.
    let gap: CGFloat

    init(_ child: ChatNode, gap: CGFloat) {
        self.child = child
        self.gap = gap
    }

    static func column(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let column = max(0, min(columnWidth, width - sidePadding * 2))
        return (((width - column) / 2).rounded(.down), column)
    }

    override var children: [ChatNode] { [child] }

    override func measure(_ width: CGFloat) -> CGSize {
        CGSize(width: width, height: child.size(for: Self.column(in: width).width).height + gap)
    }

    override func layout(_ size: CGSize, breakout: ChatBreakout) -> [ChatChildFrame] {
        let column = Self.column(in: size.width)
        let height = child.size(for: column.width).height
        return [ChatChildFrame(
            rect: CGRect(x: column.x, y: 0, width: column.width, height: height),
            breakout: ChatBreakout(leading: column.x, trailing: size.width - column.x - column.width)
        )]
    }
}
#endif
