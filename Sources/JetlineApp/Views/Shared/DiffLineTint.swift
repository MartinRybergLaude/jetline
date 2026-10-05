#if os(macOS)
import SwiftUI
import AppKit

/// Diff-line tints, shared by the full-file diff tab (AppKit, `DiffTextView`)
/// and the review-thread hunk preview in `PRTimelineNodes`. The
/// two render differently — one parses a patch, the other gets GitHub's raw
/// `diffHunk` string — but they should never disagree about what an added
/// line looks like.
enum DiffLineTint {
    static func background(_ kind: FileDiff.Line.Kind) -> Color {
        backgroundColor(kind).map { Color(nsColor: $0) } ?? .clear
    }

    static func backgroundColor(_ kind: FileDiff.Line.Kind) -> NSColor? {
        switch kind {
        case .addition: return NSColor.systemGreen.withAlphaComponent(0.10)
        case .deletion: return NSColor.systemRed.withAlphaComponent(0.10)
        case .context:  return nil
        }
    }

    static func markerColor(_ kind: FileDiff.Line.Kind) -> NSColor? {
        switch kind {
        case .addition: return .readableGreen
        case .deletion: return .systemRed
        case .context:  return nil
        }
    }

    /// `@@ … @@` header row.
    static let headerBackground = Color(nsColor: headerBackgroundColor)
    static let headerBackgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.08)

    /// Classifies a raw unified-diff line by its leading character. `nil`
    /// means a header (`@@` hunk, `---`/`+++` file, `diff --git`, `index`),
    /// which has no line kind of its own.
    static func kind<Line: StringProtocol>(ofRawLine line: Line) -> FileDiff.Line.Kind? {
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("diff --git ") || line.hasPrefix("index ") {
            return nil
        }
        switch line.first {
        case "+": return .addition
        case "-": return .deletion
        case "@": return nil
        default:  return .context
        }
    }

    /// Raw unified-diff lines as text for a `ChatTextView`: each line
    /// tinted edge to edge, headers muted, `+`/`-` markers colored.
    @MainActor
    static func attributed<Line: StringProtocol>(
        _ lines: some Collection<Line>,
        font: NSFont,
        indent: CGFloat,
        lineSpacing: CGFloat = 0
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = indent
        paragraph.headIndent = indent
        paragraph.paragraphSpacingBefore = lineSpacing
        paragraph.paragraphSpacing = lineSpacing
        let out = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let kind = kind(ofRawLine: line)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: kind == nil ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            if let tint = kind.map(backgroundColor) ?? headerBackgroundColor {
                attributes[.chatLineTint] = tint
            }
            let terminator = index < lines.count - 1 ? "\n" : ""
            let text = NSMutableAttributedString(string: (line.isEmpty ? " " : String(line)) + terminator, attributes: attributes)
            if let kind, let marker = markerColor(kind), !line.isEmpty {
                text.addAttribute(.foregroundColor, value: marker, range: NSRange(location: 0, length: 1))
            }
            out.append(text)
        }
        return out
    }
}
#endif
