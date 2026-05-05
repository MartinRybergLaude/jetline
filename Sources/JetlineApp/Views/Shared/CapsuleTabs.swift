import SwiftUI

/// Xcode-style segmented tab bar: a recessed capsule "track" with equal-width
/// segments. The selected segment is filled with an accent capsule. The
/// label closure decides what each segment renders (icon or text).
struct CapsuleTabs<Tab: Hashable, Label: View>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    var height: CGFloat = 22
    var help: ((Tab) -> String?)? = nil
    @ViewBuilder let label: (Tab, Bool) -> Label

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { idx in
                segment(tabs[idx], idx: idx)
            }
        }
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func segment(_ tab: Tab, idx: Int) -> some View {
        let isSelected = tab == selection
        let prevSelected = idx > 0 && tabs[idx - 1] == selection
        let showDivider = idx > 0 && !prevSelected && !isSelected
        return Button {
            guard !isSelected else { return }
            selection = tab
        } label: {
            label(tab, isSelected)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .contentShape(Capsule())
                .overlay(alignment: .leading) {
                    if showDivider {
                        Rectangle()
                            .fill(Color.primary.opacity(0.15))
                            .frame(width: 1, height: 14)
                    }
                }
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule().fill(Color.accentColor)
            }
        }
        .help(help?(tab) ?? "")
    }
}
