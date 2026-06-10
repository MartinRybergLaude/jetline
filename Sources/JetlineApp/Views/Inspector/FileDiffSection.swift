import SwiftUI

struct FileDiffSection: View {
    let file: FileDiff
    /// Position of the enclosing scroll view; written on collapse to
    /// re-anchor in the same transaction as the layout change.
    @Binding var scrollPosition: ScrollPosition
    /// Live contentOffset.y of the enclosing scroll view (see InspectorView).
    let scrollOffset: MutableBox<CGFloat>
    @State private var expanded: Bool = false
    /// Frame of the expanded hunk content in scroll-view viewport
    /// coordinates, updated every scroll frame. Deliberately a non-observed
    /// reference box: it's only read at collapse-tap time, and writing it
    /// from a geometry callback must not invalidate the view — observable
    /// state here creates a layout feedback loop with the pinned header
    /// that pegs the CPU.
    @State private var contentFrame = MutableBox<CGRect>(.zero)

    /// Row spacing of the enclosing LazyVStack. When the content row
    /// collapses, one row gap disappears with it, so the re-anchor math
    /// needs this value.
    static let rowSpacing: CGFloat = 8

    // A Section with a pinned header (the enclosing LazyVStack passes
    // `.sectionHeaders`): the file row sticks to the top of the scroll view
    // while its hunks scroll by, so a long file can be collapsed without
    // scrolling back up. The header gets an opaque background so pinned
    // content doesn't bleed through.
    var body: some View {
        Section {
            if expanded {
                content
                    .onGeometryChange(for: CGRect.self) { geo in
                        geo.frame(in: .scrollView)
                    } action: { contentFrame.value = $0 }
            }
        } header: {
            // NOTE: never attach geometry observation to this header — its
            // frame is rewritten by the pin adjustment during lazy layout
            // placement, so observing it re-enters layout in an infinite
            // loop (96% CPU hang). Measure the section content instead.
            header
                .padding(.vertical, 4)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var content: some View {
        if file.isBinary {
            Text("Binary file — not shown")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                // Hunk header (`@@ -a,b +c,d @@`) is unique within a
                // file's hunks for non-pathological diffs; using it as
                // the id keeps SwiftUI's diff stable when surrounding
                // file content shifts.
                ForEach(file.hunks, id: \.header) { hunk in
                    HunkView(hunk: hunk)
                }
            }
        }
    }

    private var header: some View {
        Button {
            if expanded && contentFrame.value.minY < 0 {
                // Part of this file's content is scrolled above the viewport,
                // so collapsing would yank everything below it upward by the
                // removed height. Shift the scroll offset by that same amount
                // in the same transaction, keeping the next file exactly
                // where it is on screen.
                expanded = false
                let removed = contentFrame.value.height + Self.rowSpacing
                scrollPosition.scrollTo(y: max(0, scrollOffset.value - removed))
            } else {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                statusBadge
                Text(file.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("-\(file.deletions)").foregroundStyle(.red)
            }
            .font(.system(.caption, design: .monospaced))
        }
        .buttonStyle(.plain)
    }

    private var statusBadge: some View {
        Text(file.status.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(badgeColor)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var badgeColor: Color {
        switch file.status {
        case .added: return .green
        case .deleted: return .red
        case .modified: return .blue
        case .renamed: return .orange
        case .copied: return .purple
        case .typeChange: return .gray
        case .unknown: return .secondary
        }
    }
}

/// Reference holder for layout-derived values that are read imperatively
/// (e.g. at tap time) and must not trigger view updates when written.
final class MutableBox<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

struct HunkView: View {
    let hunk: FileDiff.Hunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hunk.lines.indices, id: \.self) { idx in
                    lineView(hunk.lines[idx])
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
        .padding(.vertical, 2)
    }

    private func lineView(_ line: FileDiff.Line) -> some View {
        let style = LineStyle(kind: line.kind)
        return HStack(alignment: .top, spacing: 4) {
            Text(style.prefix)
                .foregroundStyle(style.prefixColor)
                .frame(width: 8, alignment: .leading)
            Text(line.text.isEmpty ? " " : line.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(style.background)
    }

    private struct LineStyle {
        var prefix: String
        var prefixColor: Color
        var background: Color

        init(kind: FileDiff.Line.Kind) {
            switch kind {
            case .addition:
                prefix = "+"
                prefixColor = .green
                background = Color.green.opacity(0.10)
            case .deletion:
                prefix = "-"
                prefixColor = .red
                background = Color.red.opacity(0.10)
            case .context:
                prefix = " "
                prefixColor = .secondary
                background = .clear
            }
        }
    }
}
