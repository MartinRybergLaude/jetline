import SwiftUI

/// Diff-line tints, shared by the full-file diff tab and the review-thread hunk
/// preview in `ReviewThreadCard`. The two render differently — one parses a
/// patch, the other gets GitHub's raw `diffHunk` string — but they should
/// never disagree about what an added line looks like.
enum DiffLineTint {
    static func background(_ kind: FileDiff.Line.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.10)
        case .deletion: return Color.red.opacity(0.10)
        case .context:  return .clear
        }
    }

    static func marker(_ kind: FileDiff.Line.Kind) -> Color {
        switch kind {
        case .addition: return .readableGreen
        case .deletion: return .red
        case .context:  return .secondary
        }
    }

    /// `@@ … @@` header row.
    static let headerBackground = Color.secondary.opacity(0.08)

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
