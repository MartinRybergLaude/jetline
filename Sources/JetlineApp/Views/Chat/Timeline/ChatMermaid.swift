#if os(macOS)
import AppKit

/// A rendered mermaid diagram, scaled down to fit the column (never up).
/// Its size comes from the renderer's cache, so the builder only makes one
/// once the diagram has rendered; the image itself is picked per
/// appearance when drawn. Clicking opens it in a zoomable window.
final class MermaidNode: ChatNode {
    let source: String
    let natural: CGSize

    init(source: String, natural: CGSize) {
        self.source = source
        self.natural = natural
    }

    override func measure(_ width: CGFloat) -> CGSize {
        guard natural.width > 0 else { return CGSize(width: width, height: 0) }
        let scale = min(1, width / natural.width)
        return CGSize(width: width, height: (natural.height * scale).rounded())
    }

    override var viewType: NSView.Type { ChatMermaidView.self }
    override func makeView() -> NSView { ChatMermaidView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatMermaidView else { return }
        view.show(source: source, natural: natural)
    }
}

final class ChatMermaidView: NSView {
    /// Off in the viewer window, which already shows it enlarged.
    var opensViewer = true
    private var source = ""
    private var natural = CGSize.zero
    private var image: NSImage?

    override var isFlipped: Bool { true }

    func show(source: String, natural: CGSize) {
        guard source != self.source || natural != self.natural else { return }
        self.source = source
        self.natural = natural
        image = nil
        toolTip = opensViewer ? "Click to enlarge" : nil
        updateImage()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateImage()
    }

    /// The image for the current appearance, or the other one's until it
    /// has rendered.
    private func updateImage() {
        guard !source.isEmpty else { return }
        let requested = source
        image = MermaidRenderer.shared.image(source, dark: effectiveAppearance.isDark, owner: ObjectIdentifier(self)) { [weak self] in
            guard let self, self.source == requested else { return }
            self.updateImage()
        }
        needsDisplay = true
    }

    private var imageRect: CGRect {
        guard natural.width > 0 else { return .zero }
        let scale = min(1, bounds.width / natural.width, bounds.height / natural.height)
        let size = CGSize(width: natural.width * scale, height: natural.height * scale)
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: 0, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func resetCursorRects() {
        if opensViewer { addCursorRect(imageRect, cursor: .pointingHand) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard opensViewer else { return nil }
        let local = superview.map { convert(point, from: $0) } ?? point
        return imageRect.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        MermaidViewer.open(source: source, natural: natural)
    }
}

/// A window for one diagram at full size, pinch- and scroll-zoomable. The
/// image is vector, so it stays sharp at any magnification.
@MainActor
final class MermaidViewer: NSObject, NSWindowDelegate {
    private static var windows: [MermaidViewer] = []

    private let window: NSWindow
    private let source: String

    static func open(source: String, natural: CGSize) {
        if let existing = windows.first(where: { $0.source == source }) {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let viewer = MermaidViewer(source: source, natural: natural)
        windows.append(viewer)
        viewer.window.makeKeyAndOrderFront(nil)
    }

    private init(source: String, natural: CGSize) {
        self.source = source
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900)
        let padding: CGFloat = 32
        let fit = min(1, (screen.width * 0.85 - padding * 2) / natural.width, (screen.height * 0.85 - padding * 2) / natural.height)
        let content = CGSize(
            width: max(420, natural.width * fit + padding * 2),
            height: max(280, natural.height * fit + padding * 2)
        )
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: content),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Diagram"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .textBackgroundColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 8
        scroll.drawsBackground = false
        let document = NSView(frame: CGRect(origin: .zero, size: CGSize(width: natural.width + padding * 2, height: natural.height + padding * 2)))
        let diagram = ChatMermaidView(frame: CGRect(x: padding, y: padding, width: natural.width, height: natural.height))
        diagram.opensViewer = false
        diagram.show(source: source, natural: natural)
        document.addSubview(diagram)
        scroll.documentView = document
        window.contentView = scroll
        scroll.magnification = fit
        window.center()
    }

    func windowWillClose(_ notification: Notification) {
        Self.windows.removeAll { $0 === self }
    }
}
#endif
