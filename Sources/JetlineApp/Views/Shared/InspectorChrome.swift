import SwiftUI
import AppKit

/// Small pieces of chrome shared across the inspector's panels. Each of
/// these existed in two or three near-identical copies before, which is how
/// the corner radii and opacities started drifting apart.

/// Rounded card fill + hairline border. The tints stay per-caller — a
/// resolved thread is deliberately flatter than an open one — but the
/// geometry is fixed here.
struct CardSurface: ViewModifier {
    var fill: Color
    var stroke: Color
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fill)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(stroke, lineWidth: 0.5)
                    )
            )
    }
}

extension View {
    func cardSurface(
        fill: Color = Color.secondary.opacity(0.06),
        stroke: Color = Color.secondary.opacity(0.15),
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(CardSurface(fill: fill, stroke: stroke, cornerRadius: cornerRadius))
    }
}

/// Spinner-or-arrow refresh control. `isRefreshing` and the action are the
/// caller's: the PR panel drives a tracker poll through `WorkspaceState`,
/// the comments panel drives its own store.
struct RefreshButton: View {
    let isRefreshing: Bool
    var title: String?
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                if let title { Text(title) }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(isRefreshing)
        .help(help ?? "")
    }
}

/// Trailing "open this on github.com" affordance.
struct OpenOnGitHubButton: View {
    let url: String
    var help: String = "Open on GitHub"

    var body: some View {
        if let link = URL(string: url) {
            Button {
                NSWorkspace.shared.open(link)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}
