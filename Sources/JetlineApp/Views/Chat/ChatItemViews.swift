import SwiftUI
import AppKit

/// A run of timeline rows rendered as one unit.
enum ChatSegment: Identifiable {
    case user(ChatItemBox)
    case message(ChatItemBox)
    /// Consecutive tool calls and reasoning, collapsed into one group.
    case work([ChatItemBox])
    case plan(ChatItemBox)
    case notice(ChatItemBox)
    case compaction(ChatItemBox)

    var id: String {
        switch self {
        case let .user(box), let .message(box), let .plan(box), let .notice(box), let .compaction(box):
            return box.id
        case let .work(boxes):
            return "work-" + (boxes.first?.id ?? "")
        }
    }

    /// Group a turn's items. Reads only `ChatItemBox.kind`, which never
    /// changes, so calling this from a view doesn't subscribe it to item
    /// content.
    @MainActor
    static func segments(_ boxes: [ChatItemBox]) -> [ChatSegment] {
        var segments: [ChatSegment] = []
        var work: [ChatItemBox] = []
        func flushWork() {
            if !work.isEmpty { segments.append(.work(work)) }
            work.removeAll()
        }
        for box in boxes {
            switch box.kind {
            case .work, .reasoning:
                work.append(box)
            case .user:
                flushWork()
                segments.append(.user(box))
            case .message:
                flushWork()
                segments.append(.message(box))
            case .plan:
                flushWork()
                segments.append(.plan(box))
            case .notice:
                flushWork()
                segments.append(.notice(box))
            case .compaction:
                flushWork()
                segments.append(.compaction(box))
            }
        }
        flushWork()
        return segments
    }
}

extension MarkdownStyle {
    /// Chat body text: larger than the inspector's comment style.
    static func chat(fontFamily: String? = nil, monoFamily: String? = nil) -> MarkdownStyle {
        MarkdownStyle(
            bodySize: 15, codeSize: 14, blockSpacing: 12,
            fontFamily: fontFamily, monoFamily: monoFamily, tableBodySize: 14, lineSpacing: 3
        )
    }
}

// MARK: - Diffs

/// Compact rendering of a unified diff snippet (hunks only, no file
/// headers), tinted like the diff tab.
struct InlineDiffView: View {
    let diff: String
    var maxLines = 400

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(maxLines)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let raw = String(line)
                    let kind = DiffLineTint.kind(ofRawLine: raw)
                    Text(raw.isEmpty ? " " : raw)
                        .monoFont(size: 14)
                        .foregroundStyle(kind == nil ? Color.secondary : Color.primary)
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(kind.map(DiffLineTint.background) ?? DiffLineTint.headerBackground)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Attachments

struct AttachmentThumbnail: View {
    let url: URL
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
    }
}
