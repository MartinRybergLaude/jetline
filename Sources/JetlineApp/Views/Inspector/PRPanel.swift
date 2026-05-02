import SwiftUI
import AppKit

struct PRPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let id = state.selectedWorkspaceId,
               let ws = state.workspaceById(id) {
                content(for: ws)
                    // Open / switch panel → wake the tracker for an immediate
                    // refresh. Ongoing polling is handled centrally so the
                    // panel doesn't run its own loop.
                    .onAppear { state.prTracker.kick(workspaceId: ws.id) }
                    .onChange(of: ws.id) { _, newId in
                        state.prTracker.kick(workspaceId: newId)
                    }
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func content(for workspace: Workspace) -> some View {
        switch state.prByWorkspace[workspace.id] ?? .loading {
        case .loading:
            InspectorPlaceholder(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Loading PR…"
            )
        case let .error(msg):
            InspectorPlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load PR",
                subtitle: msg
            )
        case .absent:
            InspectorPlaceholder(
                systemImage: "tray",
                title: "No pull request",
                subtitle: "Branch \(workspace.branchName) has no PR on the remote."
            )
        case let .loaded(pr, checks):
            VStack(alignment: .leading, spacing: 12) {
                PRHeaderCard(pr: pr)
                ChecksSection(checks: checks)
                HStack {
                    Spacer()
                    Button {
                        state.prTracker.kick(workspaceId: workspace.id)
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 12)
        }
    }
}

private struct PRHeaderCard: View {
    let pr: PullRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(pr.number)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(pr.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                statePill
                Text("\(pr.headRefName) → \(pr.baseRefName)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("@\(pr.author.login)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var statePill: some View {
        let (label, color): (String, Color) = {
            if pr.isDraft { return ("DRAFT", .gray) }
            switch pr.state.uppercased() {
            case "OPEN":   return ("OPEN", .green)
            case "MERGED": return ("MERGED", .purple)
            case "CLOSED": return ("CLOSED", .red)
            default:       return (pr.state.uppercased(), .secondary)
            }
        }()
        return Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct ChecksSection: View {
    let checks: [CheckRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Checks")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !checks.isEmpty {
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            if checks.isEmpty {
                Text("No checks reported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(grouped, id: \.workflow) { group in
                        if !group.workflow.isEmpty {
                            Text(group.workflow)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                                .padding(.bottom, 2)
                        }
                        ForEach(group.runs) { run in
                            CheckRow(run: run)
                        }
                    }
                }
            }
        }
    }

    private var summary: String {
        var pass = 0, fail = 0, pending = 0
        for run in checks {
            switch run.bucket {
            case .pass: pass += 1
            case .fail: fail += 1
            default:    if run.isActive { pending += 1 }
            }
        }
        var parts: [String] = []
        if pass > 0 { parts.append("\(pass)✓") }
        if fail > 0 { parts.append("\(fail)✗") }
        if pending > 0 { parts.append("\(pending)…") }
        return parts.joined(separator: " ")
    }

    private struct WorkflowGroup: Hashable {
        let workflow: String
        let runs: [CheckRun]
    }

    private var grouped: [WorkflowGroup] {
        var byWorkflow: [String: [CheckRun]] = [:]
        var order: [String] = []
        for run in checks {
            let key = run.workflow ?? ""
            if byWorkflow[key] == nil { order.append(key) }
            byWorkflow[key, default: []].append(run)
        }
        return order.map { WorkflowGroup(workflow: $0, runs: byWorkflow[$0] ?? []) }
    }
}

private struct CheckRow: View {
    let run: CheckRun

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            Text(run.name)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let link = run.link.flatMap(URL.init(string:)) {
                Button {
                    NSWorkspace.shared.open(link)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open check on GitHub")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch visual {
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.yellow)
        case .running:
            Image(systemName: "circle.dashed").foregroundStyle(.yellow)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        case .unknown:
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
    }

    private enum Visual { case pass, fail, pending, running, skipped, cancelled, unknown }

    /// Bucket wins where it disagrees with `(status, conclusion)` — gh has
    /// already collapsed edge cases like neutral-as-success there.
    private var visual: Visual {
        switch run.bucket {
        case .pass:     return .pass
        case .fail:     return .fail
        case .skipping: return .skipped
        case .cancel:   return .cancelled
        case .pending, .unknown:
            break
        }
        switch run.status {
        case .inProgress: return .running
        case .queued, .pending, .waiting, .requested: return .pending
        case .completed:
            switch run.conclusion {
            case .success, .neutral: return .pass
            case .failure, .timedOut, .actionRequired: return .fail
            case .cancelled: return .cancelled
            case .skipped:   return .skipped
            case .stale, .unknown: return .unknown
            }
        case .unknown: return .unknown
        }
    }
}
