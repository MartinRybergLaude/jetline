#if os(macOS)
import SwiftUI

/// The composer's `/` and `@` completions, shared with `ChatView`, which
/// draws the list above the timeline.
@MainActor
@Observable
final class ComposerPopup {
    var items: [ChatComposer.Suggestion] = []
    var highlighted = 0
    /// Completing file paths rather than commands.
    var showsPaths = false
    @ObservationIgnored var onAccept: ((ChatComposer.Suggestion) -> Void)?
}

struct ComposerSuggestionList: View {
    let popup: ComposerPopup
    private var monoFamily: String? { MonoFont.family }

    var body: some View {
        // The popup sits on the composer, so the details go on top: their
        // height changing with the highlight then leaves the rows in place.
        VStack(alignment: .leading, spacing: 2) {
            if !popup.showsPaths, popup.items.indices.contains(popup.highlighted),
               let detail = popup.items[popup.highlighted].detail {
                details(detail)
            }
            ForEach(Array(popup.items.enumerated()), id: \.element.id) { index, item in
                row(item, selected: index == popup.highlighted)
                    .onHover { if $0 { popup.highlighted = index } }
                    .onTapGesture { popup.onAccept?(item) }
            }
        }
        .padding(6)
        .frame(maxWidth: 560, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    /// The highlighted command's whole description, which its row cuts off.
    private func details(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 2)
            Divider()
        }
        .padding(.bottom, 4)
    }

    private func row(_ item: ChatComposer.Suggestion, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: popup.showsPaths ? "doc" : "command")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 16)
            Text(item.title)
                .font(popup.showsPaths ? .mono(size: 13, family: monoFamily) : .system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.head)
                .layoutPriority(1)
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }
}
#endif
