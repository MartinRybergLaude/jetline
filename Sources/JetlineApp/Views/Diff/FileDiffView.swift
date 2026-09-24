import SwiftUI

/// Main-area view for a diff tab: the whole file, with changed lines tinted
/// inline and old/new line numbers in the gutter. Opens scrolled to the
/// first change.
struct FileDiffView: View {
    let workspace: Workspace
    let workspaceState: WorkspaceState
    let tab: DiffTab

    @State private var loaded: FileDiff?
    /// `loaded`'s rendered rows, numbered and highlighted off the main actor.
    @State private var rows: [FileDiffLine] = []
    @State private var loadError: String?
    @State private var isLoading = true

    /// The file's entry in the changes-panel snapshot. Reloading is keyed on
    /// it, so the tab follows the FSEvents-driven refreshes that panel gets.
    private var snapshotEntry: FileDiff? {
        let snap = tab.mode == .local ? workspaceState.localDiff : workspaceState.diff
        return snap?.files.first { $0.path == tab.path }
    }

    private struct LoadKey: Equatable {
        var tab: DiffTab
        var entry: FileDiff?
    }

    var body: some View {
        let entry = snapshotEntry
        VStack(spacing: 0) {
            header(entry: entry)
                .overlay(alignment: .bottom) { Divider() }
            content(entry: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: LoadKey(tab: tab, entry: entry)) {
            await load(entry: entry)
        }
    }

    private func load(entry: FileDiff?) async {
        guard let entry else {
            loaded = nil
            loadError = nil
            isLoading = false
            return
        }
        do {
            let file = try await DiffComputer.fullFileDiff(
                path: tab.path,
                status: entry.status,
                worktreePath: workspace.worktreePath,
                baseBranch: workspace.baseBranch,
                mode: tab.mode
            )
            let language = SyntaxLanguage.forPath(tab.path)
            let rows = await Task.detached(priority: .userInitiated) {
                file.map { FileDiffLine.lines(for: $0, language: language) } ?? []
            }.value
            guard !Task.isCancelled else { return }
            loaded = file
            self.rows = rows
            loadError = nil
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func header(entry: FileDiff?) -> some View {
        HStack(spacing: 8) {
            if let entry {
                FileStatusBadge(status: entry.status)
            }
            Text(tab.path)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Text(tab.mode == .local ? "uncommitted" : "vs \(workspace.baseBranch)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let entry {
                Group {
                    Text("+\(entry.additions)").foregroundStyle(Color.readableGreen)
                    Text("−\(entry.deletions)").foregroundStyle(.red)
                }
                .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func content(entry: FileDiff?) -> some View {
        if let loadError {
            InspectorPlaceholder(systemImage: "exclamationmark.triangle", title: loadError)
        } else if let loaded {
            if loaded.isBinary {
                InspectorPlaceholder(systemImage: "doc", title: "Binary file — not shown")
            } else {
                FileDiffLines(lines: rows)
                    .id(tab)
            }
        } else if isLoading {
            ProgressView()
        } else {
            InspectorPlaceholder(
                systemImage: "checkmark.circle",
                title: tab.mode == .local
                    ? "No uncommitted changes to this file"
                    : "No changes to this file vs \(workspace.baseBranch)"
            )
        }
    }
}

private struct FileDiffLines: View {
    let lines: [FileDiffLine]
    @State private var didScrollToFirstChange = false

    var body: some View {
        let digits = max(3, String(lines.compactMap { $0.newNumber ?? $0.oldNumber }.max() ?? 0).count)
        let gutterWidth = CGFloat(digits) * 7 + 8
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        row(line, gutterWidth: gutterWidth).id(line.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .onAppear {
                guard !didScrollToFirstChange else { return }
                didScrollToFirstChange = true
                if let first = lines.first(where: { $0.kind != .context && !$0.isHunkHeader }) {
                    proxy.scrollTo(first.id, anchor: UnitPoint(x: 0, y: 0.25))
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ line: FileDiffLine, gutterWidth: CGFloat) -> some View {
        if line.isHunkHeader {
            Text(line.text)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DiffLineTint.headerBackground)
                .font(.system(size: 11, design: .monospaced))
        } else {
            HStack(alignment: .top, spacing: 0) {
                lineNumber(line.oldNumber, width: gutterWidth)
                lineNumber(line.newNumber, width: gutterWidth)
                Text(marker(line.kind))
                    .foregroundStyle(DiffLineTint.marker(line.kind))
                    .frame(width: 16)
                Text(line.highlighted ?? AttributedString(line.text.isEmpty ? " " : line.text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.vertical, 1)
            .background(DiffLineTint.background(line.kind))
        }
    }

    private func lineNumber(_ n: Int?, width: CGFloat) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: width, alignment: .trailing)
    }

    private func marker(_ kind: FileDiff.Line.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context:  return ""
        }
    }
}

/// One rendered row of a full-file diff, with its old/new line numbers.
struct FileDiffLine: Identifiable, Equatable {
    let id: Int
    var kind: FileDiff.Line.Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    var isHunkHeader = false
    /// Syntax-colored text; plain `text` when the language is unknown.
    var highlighted: AttributedString?

    /// Rows for `file`, numbering lines from each hunk's `@@ -a,b +c,d @@`
    /// header. Headers get a row of their own only between hunks — a
    /// full-context diff is one hunk, and its header says nothing the gutter
    /// doesn't.
    ///
    /// With a `language`, each side of the diff is highlighted as its own
    /// file — the old file is context + deletions, the new one context +
    /// additions — so a block comment opened in a deleted line doesn't bleed
    /// into the added lines after it.
    static func lines(for file: FileDiff, language: SyntaxLanguage? = nil) -> [FileDiffLine] {
        let highlighter = language.map(SyntaxHighlighter.init)
        var oldState = SyntaxHighlighter.State.normal
        var newState = SyntaxHighlighter.State.normal
        var rows: [FileDiffLine] = []
        for hunk in file.hunks {
            var (old, new) = startLines(ofHunkHeader: hunk.header)
            if file.hunks.count > 1 {
                rows.append(FileDiffLine(id: rows.count, kind: .context, text: hunk.header, isHunkHeader: true))
            }
            for line in hunk.lines {
                var row = FileDiffLine(id: rows.count, kind: line.kind, text: line.text)
                if let highlighter {
                    let segments: [SyntaxSegment]
                    switch line.kind {
                    case .deletion:
                        segments = highlighter.tokenize(line.text, state: &oldState)
                    case .addition:
                        segments = highlighter.tokenize(line.text, state: &newState)
                    case .context:
                        // Both sides see this line. Their states only differ
                        // right after a change that left something open.
                        let statesMatch = oldState == newState
                        segments = highlighter.tokenize(line.text, state: &newState)
                        if statesMatch {
                            oldState = newState
                        } else {
                            _ = highlighter.tokenize(line.text, state: &oldState)
                        }
                    }
                    // An empty AttributedString would collapse the row.
                    if !line.text.isEmpty {
                        row.highlighted = SyntaxTheme.attributed(segments)
                    }
                }
                switch line.kind {
                case .context:
                    row.oldNumber = old; row.newNumber = new
                    old += 1; new += 1
                case .deletion:
                    row.oldNumber = old
                    old += 1
                case .addition:
                    row.newNumber = new
                    new += 1
                }
                rows.append(row)
            }
        }
        return rows
    }

    /// `(a, c)` from `@@ -a[,b] +c[,d] @@`. A zero start (pure add/delete
    /// side) numbers from 1 so the other side still counts correctly.
    static func startLines(ofHunkHeader header: String) -> (Int, Int) {
        func start(after sign: Character) -> Int {
            guard let range = header.firstIndex(of: sign) else { return 1 }
            let digits = header[header.index(after: range)...].prefix(while: \.isNumber)
            return max(1, Int(digits) ?? 1)
        }
        return (start(after: "-"), start(after: "+"))
    }
}

/// Coloured one-letter status chip (`M`, `A`, `D`, …) used by the changes
/// panel rows and the diff tab header.
struct FileStatusBadge: View {
    let status: FileDiff.Status

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(status.label)
    }

    private var color: Color {
        switch status {
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
