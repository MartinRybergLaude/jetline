#if os(macOS)
import AppKit
import SwiftMath

// TeX math in chat markdown, typeset natively by SwiftMath. Inline spans are
// text attachments sitting on the text's baseline; display blocks are nodes
// of their own. Both draw in the text color at draw time, so an appearance
// flip recolors them without a rebuild.

@MainActor
enum ChatMath {
    /// A nil value: the TeX doesn't parse, so don't retry it.
    private static let cache: NSCache<NSString, CacheBox<MTTypesetMath?>> = {
        let cache = NSCache<NSString, CacheBox<MTTypesetMath?>>()
        cache.countLimit = 1000
        return cache
    }()

    /// Latin Modern reads small beside the UI font at the same point size.
    static func fontSize(forText size: CGFloat) -> CGFloat {
        (size * 1.12).rounded()
    }

    /// Nil when `tex` doesn't parse.
    static func typeset(_ tex: String, size: CGFloat, display: Bool) -> MTTypesetMath? {
        let key = "\(size)|\(display ? 1 : 0)|\(tex)" as NSString
        if let hit = cache.object(forKey: key) { return hit.value }
        let math = MTTypesetMath(latex: tex, fontSize: size, displayStyle: display)
        cache.setObject(CacheBox(math), forKey: key)
        return math
    }

    /// An inline formula carrying `attributes` (link, color intent). Falls
    /// back to the TeX source, as code, when it doesn't parse.
    static func inline(
        _ span: MarkdownMath.Span,
        textSize: CGFloat,
        secondary: Bool,
        attributes: [NSAttributedString.Key: Any],
        codeFont: @autoclosure () -> NSFont
    ) -> NSAttributedString {
        guard let math = typeset(span.tex, size: fontSize(forText: textSize), display: span.display) else {
            var fallback = attributes
            fallback[.font] = codeFont()
            let source = span.display ? "$$\(span.tex)$$" : "$\(span.tex)$"
            return NSAttributedString(string: source, attributes: fallback)
        }
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(math: math, tex: span.tex, secondary: secondary)
        let out = NSMutableAttributedString(attachment: attachment)
        var kept = attributes
        kept[.font] = nil
        out.addAttributes(kept, range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Draws `math` with its baseline's left end at `origin`, in a flipped
    /// view's coordinates unless `flipped` is false.
    static func draw(_ math: MTTypesetMath, baseline origin: CGPoint, secondary: Bool, flipped: Bool = true) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        if flipped { context.scaleBy(x: 1, y: -1) }
        context.textMatrix = .identity
        math.draw(context, baseline: .zero, color: secondary ? .secondaryLabelColor : .labelColor)
        context.restoreGState()
    }
}

/// An inline formula, sized and baselined by its typeset metrics.
final class MathAttachmentCell: NSTextAttachmentCell {
    let math: MTTypesetMath
    let tex: String
    let secondary: Bool

    init(math: MTTypesetMath, tex: String, secondary: Bool) {
        self.math = math
        self.tex = tex
        self.secondary = secondary
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func cellSize() -> NSSize {
        NSSize(width: ceil(math.width) + 2, height: ceil(math.ascent + math.descent))
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -ceil(math.descent))
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let flipped = controlView?.isFlipped ?? true
        let descent = ceil(math.descent)
        let baseline = CGPoint(x: cellFrame.minX + 1, y: flipped ? cellFrame.maxY - descent : cellFrame.minY + descent)
        ChatMath.draw(math, baseline: baseline, secondary: secondary, flipped: flipped)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int) {
        draw(withFrame: cellFrame, in: controlView)
    }

    override func wantsToTrackMouse() -> Bool { false }
}

/// A display formula, centered in its width. Wider than that, the
/// surrounding scroller takes over.
final class MathBlockNode: ChatNode {
    let math: MTTypesetMath
    let secondary: Bool
    static let padding: CGFloat = 4

    init(math: MTTypesetMath, secondary: Bool) {
        self.math = math
        self.secondary = secondary
    }

    override func measure(_ width: CGFloat) -> CGSize {
        CGSize(width: ceil(math.width) + 2, height: ceil(math.ascent + math.descent) + Self.padding * 2)
    }

    override var viewType: NSView.Type { ChatMathView.self }
    override func makeView() -> NSView { ChatMathView() }
    override func configure(_ view: NSView, size: CGSize) {
        guard let view = view as? ChatMathView else { return }
        guard view.math !== math || view.secondary != secondary else { return }
        view.math = math
        view.secondary = secondary
        view.needsDisplay = true
    }
}

final class ChatMathView: NSView {
    var math: MTTypesetMath?
    var secondary = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let math else { return }
        let x = max(1, ((bounds.width - math.width) / 2).rounded())
        let baseline = MathBlockNode.padding + ceil(math.ascent)
        ChatMath.draw(math, baseline: CGPoint(x: x, y: baseline), secondary: secondary)
    }
}
#endif
