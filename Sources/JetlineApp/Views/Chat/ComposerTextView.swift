import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Keys the composer's popups (slash commands, file mentions) want first.
enum ComposerKey {
    case up
    case down
    case accept
    case dismiss
}

/// The composer's text field. AppKit rather than `TextField(axis:)`
/// because a chat composer needs things SwiftUI's field can't do: Return
/// sends while Shift-Return breaks the line, arrow keys drive a popup
/// without moving the caret, the caret position feeds `@` completion, and
/// pasted or dropped images become attachments instead of text.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var isFocused: Bool
    /// Caret offset (UTF-16) changes, for token completion.
    var onCaretChange: (Int) -> Void
    var onSubmit: () -> Void
    /// Return true to consume the key.
    var onPopupKey: (ComposerKey) -> Bool
    var onEscape: () -> Void
    var onImages: ([URL]) -> Void
    /// Set by the parent to replace text programmatically (completions);
    /// the caret lands at the given offset.
    var replacement: Replacement?

    struct Replacement: Equatable {
        let id = UUID()
        var text: String
        var caret: Int
    }

    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 220

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let textView = ComposerNSTextView()
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.placeholder = placeholder
        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        textView.string = text
        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? ComposerNSTextView else { return }
        textView.placeholder = placeholder
        if let replacement, replacement != context.coordinator.appliedReplacement {
            context.coordinator.appliedReplacement = replacement
            textView.string = replacement.text
            let caret = min(replacement.caret, (replacement.text as NSString).length)
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            DispatchQueue.main.async { self.text = replacement.text }
        } else if textView.string != text {
            textView.string = text
        }
        context.coordinator.recalculateHeight()
        if isFocused, textView.window != nil, textView.window?.firstResponder !== textView {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var appliedReplacement: Replacement?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
            parent.onCaretChange(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.onCaretChange(textView.selectedRange().location)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                    || NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                if parent.onPopupKey(.accept) { return true }
                parent.onSubmit()
                return true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onPopupKey(.accept)
            case #selector(NSResponder.moveUp(_:)):
                return parent.onPopupKey(.up)
            case #selector(NSResponder.moveDown(_:)):
                return parent.onPopupKey(.down)
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.onPopupKey(.dismiss) { return true }
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        func recalculateHeight() {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height + textView.textContainerInset.height * 2
            let height = min(max(used, ComposerTextView.minHeight), ComposerTextView.maxHeight)
            if abs(height - parent.height) > 0.5 {
                DispatchQueue.main.async { self.parent.height = height }
            }
        }

        func receiveImages(_ urls: [URL]) {
            parent.onImages(urls)
        }
    }
}

final class ComposerNSTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    var placeholder: String = "" {
        didSet { if oldValue != placeholder { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: font ?? .systemFont(ofSize: 13)
        ]
        let origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: Images

    override func paste(_ sender: Any?) {
        if pasteImages(from: .general) { return }
        pasteAsPlainText(sender)
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if pasteImages(from: pboard) { return true }
        return super.readSelection(from: pboard, type: type)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let images = urls.filter(Self.isImage)
            let others = urls.filter { !Self.isImage($0) }
            if !images.isEmpty { coordinator?.receiveImages(images) }
            if !others.isEmpty {
                insertText(others.map { "@" + Self.mentionPath($0.path) }.joined(separator: " ") + " ", replacementRange: selectedRange())
            }
            return true
        }
        if pasteImages(from: pboard) { return true }
        return super.performDragOperation(sender)
    }

    /// Image data (screenshots, browser drags) goes to a temp PNG; image
    /// files are attached as-is.
    private func pasteImages(from pboard: NSPasteboard) -> Bool {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let images = urls.filter(Self.isImage)
            guard images.count == urls.count else { return false }
            coordinator?.receiveImages(images)
            return true
        }
        guard pboard.data(forType: .png) != nil || pboard.data(forType: .tiff) != nil,
              let image = NSImage(pasteboard: pboard),
              let url = Self.persist(image) else { return false }
        coordinator?.receiveImages([url])
        return true
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    static func persist(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jetline-chat-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString.prefix(8)).png")
        return (try? png.write(to: url)) != nil ? url : nil
    }

    private static func mentionPath(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }
}
