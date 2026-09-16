import SwiftUI

/// Centered icon + caption used by the inspector for empty / loading /
/// error states across panels.
struct InspectorPlaceholder: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// The three non-`.loaded` PR states, rendered identically by the PR and
/// Comments tabs. Shared so the two can't drift apart — in particular the
/// "no PR on the remote" wording, which names the branch.
struct PRSnapshotPlaceholder: View {
    let snapshot: PRSnapshot
    let branchName: String

    var body: some View {
        switch snapshot {
        case .loading:
            InspectorPlaceholder(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Loading PR…"
            )
        case let .error(message):
            InspectorPlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load PR",
                subtitle: message
            )
        case .absent:
            InspectorPlaceholder(
                systemImage: "tray",
                title: "No pull request",
                subtitle: "Branch \(branchName) has no PR on the remote."
            )
        case .loaded:
            EmptyView()
        }
    }
}
