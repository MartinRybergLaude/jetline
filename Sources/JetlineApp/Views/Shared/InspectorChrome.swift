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

/// Circular GitHub avatar, falling back to the login's initial on a color
/// derived from the login itself. The fallback is what's on screen for the
/// first frame of every comment, so it has to look deliberate rather than
/// like a missing image.
struct AvatarView: View {
    let url: String?
    let login: String
    var size: CGFloat = 16

    @ObservedObject private var loader = AvatarLoader.shared

    var body: some View {
        Group {
            if let url, let image = loader.image(for: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // Bots and light-on-white avatars need an edge to read as a disc.
        .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var fallback: some View {
        Circle()
            .fill(Self.tint(for: login))
            .overlay(
                Text(initial)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    private var initial: String {
        login.first.map { String($0).uppercased() } ?? "?"
    }

    /// Stable per login so the same person keeps the same color across
    /// launches — `hashValue` is seeded per process and would not.
    private static func tint(for login: String) -> Color {
        var hash: UInt64 = 5381
        for byte in login.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.65)
    }
}
