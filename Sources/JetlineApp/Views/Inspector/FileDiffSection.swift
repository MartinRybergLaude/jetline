import SwiftUI

struct FileDiffSection: View {
    let file: FileDiff
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if expanded {
                if file.isBinary {
                    Text("Binary file — not shown")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                } else {
                    // Hunk header (`@@ -a,b +c,d @@`) is unique within a
                    // file's hunks for non-pathological diffs; using it as
                    // the id keeps SwiftUI's diff stable when surrounding
                    // file content shifts. Falls back to position when
                    // headers happen to collide.
                    ForEach(Array(file.hunks.enumerated()), id: \.element.header) { _, hunk in
                        HunkView(hunk: hunk)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
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

            ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                lineView(line)
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
