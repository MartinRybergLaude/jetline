#if os(macOS)
import SwiftUI

/// The ⌘K switcher's query, results and highlighted row, shared between
/// the view and `QuickOpenController`, which feeds it the arrow keys.
@MainActor
@Observable
final class QuickOpenModel {
    var query = ""
    private(set) var results: [QuickOpenItem] = []
    private(set) var highlighted = 0
    private var items: [QuickOpenItem]

    init(items: [QuickOpenItem]) {
        self.items = items
        results = items
    }

    var highlightedItem: QuickOpenItem? {
        results.indices.contains(highlighted) ? results[highlighted] : nil
    }

    func queryChanged() {
        results = QuickOpen.rank(items, query: query)
        highlighted = 0
    }

    func highlight(_ index: Int) {
        guard results.indices.contains(index) else { return }
        highlighted = index
    }

    /// Wraps around at either end.
    func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlighted = (highlighted + delta + results.count) % results.count
    }
}

struct QuickOpenView: View {
    @EnvironmentObject private var state: AppState
    @Bindable var model: QuickOpenModel
    let onOpen: (QuickOpenItem) -> Void
    @FocusState private var fieldFocused: Bool

    static let width: CGFloat = 600
    static let fieldHeight: CGFloat = 52
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 2
    static let listPadding: CGFloat = 6
    static let visibleRows = 8
    /// The tallest the card gets: the field and `visibleRows` rows.
    static let maxHeight = fieldHeight + 1 + CGFloat(visibleRows) * (rowHeight + rowSpacing) + listPadding * 2

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if !model.results.isEmpty {
                Divider()
                resultList
            } else if !model.query.isEmpty {
                Divider()
                Text("No matching workspaces")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .frame(width: Self.width)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .defaultFocus($fieldFocused, true)
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Open a workspace or branch", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($fieldFocused)
                .onChange(of: model.query) { model.queryChanged() }
                .onSubmit {
                    if let item = model.highlightedItem { onOpen(item) }
                }
        }
        .padding(.horizontal, 16)
        .frame(height: Self.fieldHeight)
    }

    private var resultList: some View {
        let rows = min(model.results.count, Self.visibleRows)
        let height = CGFloat(rows) * Self.rowHeight + CGFloat(max(rows - 1, 0)) * Self.rowSpacing + Self.listPadding * 2
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        row(item, highlighted: index == model.highlighted)
                            .id(item.id)
                            .onHover { if $0 { model.highlight(index) } }
                            .onTapGesture { onOpen(item) }
                    }
                }
                .padding(Self.listPadding)
            }
            .frame(height: height)
            .onChange(of: model.highlighted) {
                guard let id = model.highlightedItem?.id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func row(_ item: QuickOpenItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            icon(for: item, highlighted: highlighted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(highlighted ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(item.branch)
                    .font(.mono(size: 11, family: MonoFont.family))
                    .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(location(of: item))
                .font(.system(size: 12))
                .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
            Circle()
                .fill(highlighted ? Color.white : Color.accentColor)
                .frame(width: 6, height: 6)
                .opacity(item.isOpen ? 1 : 0)
                .help(item.isOpen ? "Open" : "")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background {
            if highlighted {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func icon(for item: QuickOpenItem, highlighted: Bool) -> some View {
        switch item.kind {
        case .repositoryHead:
            Image(systemName: "folder")
                .font(.system(size: 14))
                .foregroundStyle(highlighted ? Color.white : Color.secondary)
        case .workspace:
            PRStatusIcon(snapshot: state.workspaceState(for: item.id).pr, size: 14)
        }
    }

    private func location(of item: QuickOpenItem) -> String {
        [item.repositoryName, item.hostName].compactMap { $0 }.joined(separator: " · ")
    }
}
#endif
