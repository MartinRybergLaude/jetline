import SwiftUI

/// Hidden debug window content. Opens from the Debug menu in the menu bar
/// (`⌘⌥⇧A`). Renders the in-memory `ActivityLog` newest-first so the most
/// recent event is always at the top — answers "when did X last happen?"
/// without scrolling.
struct ActivityLogView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ActivityLogContent(log: state.activityLog, state: state)
    }
}

private struct ActivityLogContent: View {
    @ObservedObject var log: ActivityLog
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 480, minHeight: 320)
    }

    private var header: some View {
        HStack {
            Text(countLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear") { log.clear() }
                .controlSize(.small)
                .disabled(log.events.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var countLabel: String {
        let n = log.events.count
        return "\(n) event\(n == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var content: some View {
        if log.events.isEmpty {
            VStack {
                Spacer()
                Text("No activity yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(log.events.reversed())) { event in
                        ActivityRow(event: event, repoName: repoName(for: event.repoId))
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func repoName(for repoId: String?) -> String? {
        guard let repoId else { return nil }
        return state.repositories.first { $0.id == repoId }?.name
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let repoName: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }
            Text(Self.timeFormatter.string(from: event.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(repoName ?? "—")
                .font(.system(size: 11))
                .foregroundStyle(repoName == nil ? .tertiary : .secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(event.message)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch event.kind {
        case .fetch:       return .blue
        case .fastForward: return .green
        case .prPoll:      return .purple
        case .gitAction:   return .orange
        case .lifecycle:   return .gray
        case .error:       return .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
