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
                .monoFont(.callout)
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
                .monoFont(.caption)
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
                DiffTextView(lines: rows)
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

/// One rendered row of a full-file diff, with its new-file line number.
struct FileDiffLine: Identifiable, Equatable {
    let id: Int
    var kind: FileDiff.Line.Kind
    var text: String
    var newNumber: Int?
    var isHunkHeader = false
    /// Syntax-colored runs of `text`; nil when the language is unknown.
    var segments: [SyntaxSegment]?

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
            var new = newStartLine(ofHunkHeader: hunk.header)
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
                    row.segments = segments
                }
                if line.kind != .deletion {
                    row.newNumber = new
                    new += 1
                }
                rows.append(row)
            }
        }
        return rows
    }

    /// `c` from `@@ -a[,b] +c[,d] @@`. A zero start (a deleted file) numbers
    /// from 1.
    static func newStartLine(ofHunkHeader header: String) -> Int {
        guard let plus = header.firstIndex(of: "+") else { return 1 }
        let digits = header[header.index(after: plus)...].prefix(while: \.isNumber)
        return max(1, Int(digits) ?? 1)
    }
}

/// Coloured one-letter status chip (`M`, `A`, `D`, …) used by the changes
/// panel rows and the diff tab header.
struct FileStatusBadge: View {
    let status: FileDiff.Status

    var body: some View {
        Text(status.rawValue)
            .monoFont(size: 9, weight: .bold)
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
