#if os(macOS)
import SwiftUI
import AppKit

/// The PR tab's comment box, for top-level comments and thread replies
/// alike: a card-like field that grows with its text, with the send button
/// inside its corner. ⌘↩ sends; Return breaks the line.
///
/// AppKit so the placeholder is drawn by the text view itself, at its text
/// origin: `TextEditor` pads its text by insets it doesn't expose, so an
/// overlaid placeholder never lined up with the caret.
final class CommentFieldView: NSView, NSTextViewDelegate {
    static let font = NSFont.systemFont(ofSize: 13)
    private static let padding = NSEdgeInsets(top: 9, left: 11, bottom: 9, right: 8)
    private static let buttonSide: CGFloat = 24
    private static let buttonGap: CGFloat = 6
    private static let minLines: CGFloat = 2
    private static let maxLines: CGFloat = 8
    private static let lineHeight = ChatFonts.lineHeight(font)

    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    /// The height `height(for:width:)` gives changed with the text.
    var onHeightChange: (() -> Void)?

    private let scroll = NSScrollView()
    private let textView = CommentTextView.make()
    private let sendButton = CommentSendButton()
    private var focused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous

        textView.delegate = self
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onFocusChange = { [weak self] focused in
            self?.focused = focused
            self?.needsDisplay = true
        }
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        addSubview(scroll)

        sendButton.action = { [weak self] in self?.submit() }
        addSubview(sendButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.inspectorCard.cgColor
        layer?.borderColor = (focused ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.secondary(0.25)).cgColor
        layer?.borderWidth = focused ? 1 : 0.5
    }

    /// Everything but the text: the field's height is exactly this plus
    /// the text's, clamped to its line limits.
    static func height(for text: String, width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - padding.left - padding.right - buttonSide - buttonGap)
        let measured = ChatTextMeasure.size(
            NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font]),
            width: textWidth
        ).height
        let textHeight = min(max(measured, lineHeight * minLines), lineHeight * maxLines)
        return ceil(textHeight + padding.top + padding.bottom)
    }

    override func layout() {
        super.layout()
        let padding = Self.padding
        let side = Self.buttonSide
        sendButton.frame = NSRect(
            x: bounds.maxX - padding.right - side,
            y: bounds.maxY - padding.right - side,
            width: side,
            height: side
        )
        scroll.frame = NSRect(
            x: padding.left,
            y: padding.top,
            width: max(0, bounds.width - padding.left - padding.right - side - Self.buttonGap),
            height: max(0, bounds.height - padding.top - padding.bottom)
        )
        // At least as tall as the field, so a click anywhere in it lands
        // in the text.
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: scroll.contentSize.width, height: ChatNode.unbounded)
        textView.frame.size.width = scroll.contentSize.width
        if textView.frame.height < scroll.contentSize.height {
            textView.frame.size.height = scroll.contentSize.height
        }
        textView.textContainer?.size = NSSize(width: scroll.contentSize.width, height: ChatNode.unbounded)
    }

    func set(text: String, placeholder: String, canSend: Bool, isSending: Bool, sendHelp: String) {
        if textView.string != text { textView.string = text }
        textView.placeholder = placeholder
        textView.isEditable = !isSending
        sendButton.isEnabled = canSend && !isSending
        sendButton.isBusy = isSending
        sendButton.toolTip = sendHelp
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(textView)
        }
    }

    private func submit() {
        guard sendButton.isEnabled else { return }
        onSubmit?()
    }

    func textDidChange(_ notification: Notification) {
        textView.needsDisplay = true
        let text = textView.string
        onChange?(text)
        if bounds.width > 0, abs(Self.height(for: text, width: bounds.width) - bounds.height) > 0.5 {
            onHeightChange?()
        }
    }
}

/// TextKit 1, so layout matches `ChatTextMeasure`.
private final class CommentTextView: NSTextView {
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var onSubmit: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    static func make() -> CommentTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: ChatNode.unbounded))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        let view = CommentTextView(frame: .zero, textContainer: container)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = CommentFieldView.font
        view.textColor = .labelColor
        view.typingAttributes = [.font: CommentFieldView.font, .foregroundColor: NSColor.labelColor]
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        return view
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: CommentFieldView.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Round send button: accent-filled arrow when there's something to send,
/// a spinner while it goes.
private final class CommentSendButton: NSView {
    var action: (() -> Void)?
    var isEnabled = false {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            spinner.isHidden = !isBusy
            if isBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            needsDisplay = true
        }
    }
    private var pressed = false
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        addSubview(spinner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        spinner.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isBusy else { return }
        let fill: NSColor = isEnabled ? .controlAccentColor : .secondary(0.15)
        (pressed ? fill.shadow(withLevel: 0.2) ?? fill : fill).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard let arrow = ChatSymbols.image("arrow.up", size: 12, weight: .bold) else { return }
        let color: NSColor = isEnabled ? .white : .tertiaryLabelColor
        let tinted = NSImage(size: arrow.size, flipped: false) { rect in
            arrow.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: bounds.midX - arrow.size.width / 2, y: bounds.midY - arrow.size.height / 2)
        tinted.draw(in: NSRect(origin: origin, size: arrow.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isBusy else { return }
        pressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }
}

// MARK: - SwiftUI

/// `CommentFieldView` for SwiftUI, sized by its text.
struct CommentField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isSending: Bool
    var sendHelp = "Comment (⌘↩)"
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> CommentFieldView {
        CommentFieldView()
    }

    func updateNSView(_ view: CommentFieldView, context: Context) {
        let binding = $text
        view.onChange = { text in
            if binding.wrappedValue != text { binding.wrappedValue = text }
        }
        view.onSubmit = onSubmit
        view.set(
            text: text,
            placeholder: placeholder,
            canSend: text.nonBlank != nil,
            isSending: isSending,
            sendHelp: sendHelp
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommentFieldView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: CommentFieldView.height(for: text, width: width))
    }
}
#endif
