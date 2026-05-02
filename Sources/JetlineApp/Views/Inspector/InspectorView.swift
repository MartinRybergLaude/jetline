import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .changes

    enum Tab: Hashable { case changes, pr, run }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Run output owns its own ScrollView (autoscroll-to-tail), so it sits
    /// directly in the layout; the diff/PR panels are static content and get
    /// wrapped in a scroll view here.
    @ViewBuilder
    private var content: some View {
        switch tab {
        case .changes:
            ScrollView { ChangesPanel().padding(.vertical, 8) }
        case .pr:
            ScrollView { PRPanel().padding(.vertical, 8) }
        case .run:
            RunOutputPanel()
        }
    }

    private var header: some View {
        InspectorTabBar(selection: $tab)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
    }
}

/// Xcode-style inspector tabs: a recessed capsule "track" with icon-only
/// segments. The selected segment is an inset blue capsule that slides between
/// positions via `matchedGeometryEffect`.
private struct InspectorTabBar: View {
    @Binding var selection: InspectorView.Tab
    @Namespace private var ns

    private struct Item {
        let tab: InspectorView.Tab
        let symbol: String
        let help: String
    }

    private let items: [Item] = [
        Item(tab: .changes, symbol: "pencil", help: "Changes"),
        Item(tab: .pr, symbol: "arrow.triangle.pull", help: "Pull request"),
        Item(tab: .run, symbol: "terminal", help: "Run output")
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.tab) { idx, item in
                segment(item, showLeadingDivider: showDivider(before: idx))
            }
        }
        .background(
            Capsule().fill(Color.primary.opacity(0.08))
        )
    }

    /// Hairline shows between adjacent unselected segments — never on the
    /// edges of the selected pill.
    private func showDivider(before idx: Int) -> Bool {
        guard idx > 0 else { return false }
        return items[idx - 1].tab != selection && items[idx].tab != selection
    }

    private func segment(_ item: Item, showLeadingDivider: Bool) -> some View {
        let isSelected = item.tab == selection
        return Button {
            guard !isSelected else { return }
            withAnimation(.snappy(duration: 0.18)) {
                selection = item.tab
            }
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .contentShape(Capsule())
                .overlay(alignment: .leading) {
                    if showLeadingDivider {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1, height: 14)
                    }
                }
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor)
                    .matchedGeometryEffect(id: "selection", in: ns)
            }
        }
        .help(item.help)
    }
}
