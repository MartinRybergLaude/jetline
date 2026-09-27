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
    /// means a hunk header, which has no line kind of its own.
    static func kind(ofRawLine line: String) -> FileDiff.Line.Kind? {
        switch line.first {
        case "+": return .addition
        case "-": return .deletion
        case "@": return nil
        default:  return .context
        }
    }
}
#endif
