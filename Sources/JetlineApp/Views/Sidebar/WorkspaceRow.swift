#if os(macOS)
import SwiftUI
import AppKit

/// Horizontal rhythm shared by repository headers and workspace rows, so
/// every icon sits in one column and every label starts at one edge, as in
/// the Music and Finder sidebars.
enum SidebarMetrics {
    /// From the row's content origin to the disclosure chevron; machine
    /// titles start here too.
    static let leading: CGFloat = 5
    static let disclosureColumn: CGFloat = 10
    /// From the row's content origin to the icon column.
    static let iconLeading: CGFloat = 18
    static let iconColumn: CGFloat = 24
    static let labelGap: CGFloat = 6
}

struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    /// Levels deep in a stack; 0 for a workspace on the default branch.
    var depth: Int = 0
    let onStackNew: () -> Void

    var body: some View {
        // Inner view observes the per-workspace state directly so a poll
        // landing on a *different* workspace doesn't invalidate this row.
        WorkspaceRowContent(
            workspace: workspace,
            workspaceState: state.workspaceState(for: workspace.id),
            isSelected: state.selectedWorkspaceId == workspace.id,
            depth: depth,
            creator: workspace.createdByWorkspaceId.map { state.workspaceById($0)?.name ?? "a workspace since deleted" },
            onStackNew: onStackNew,
            onRename: { state.renameWorkspace(workspace, to: $0) },
            onDelete: { Task { await state.deleteWorkspace(workspace) } },
            onClose: { state.closeWorkspace(workspace.id) }
        )
    }
}

private struct WorkspaceRowContent: View {
    let workspace: Workspace
    let workspaceState: WorkspaceState
    let isSelected: Bool
    let depth: Int
    /// Name of the workspace whose agent created this one.
    let creator: String?
    let onStackNew: () -> Void
    let onRename: (String) -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var renaming = false
    @State private var draftName = ""

    var body: some View {
        let isOpen = workspaceState.hasAgentTabs
        HStack(spacing: 0) {
            if depth > 0 {
                // Each level steps one icon column in, so the elbow drops
                // from the center of the parent's icon. Capped so a tall
                // stack doesn't walk the name off the row.
                Spacer().frame(width: CGFloat(min(depth, 3) - 1) * SidebarMetrics.iconColumn)
                StackElbow()
                    .frame(width: SidebarMetrics.iconColumn, height: 16)
            }
            PRStatusIcon(snapshot: workspaceState.pr, size: 16)
                .frame(width: SidebarMetrics.iconColumn)
            Spacer().frame(width: SidebarMetrics.labelGap)
            Text(workspace.name)
                .font(.body)
                .foregroundStyle(nameColor(isOpen: isOpen))
                .lineLimit(1)
                .truncationMode(.tail)
            if let creator {
                Image(systemName: "sparkle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .help(creatorHelp(creator))
            }
            Spacer(minLength: 0)
            ChatActivityIndicator(chats: workspaceState.chats)
        }
        // Same icon column and label edge as the repository header above.
        .padding(.leading, SidebarMetrics.iconLeading)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .accessibilityValue(isOpen ? "Open" : "")
        .contentShape(Rectangle())
        .contextMenu {
            Button("New workspace stacked on this…") { onStackNew() }
            Button("Rename…") {
                draftName = workspace.name
                renaming = true
            }
            Divider()
            Button("Reveal worktree in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.worktreePath)])
            }
            if workspaceState.hasAgentTabs {
                Button("Close workspace") { onClose() }
            }
            Divider()
            Button("Delete workspace", role: .destructive) { onDelete() }
        }
        .alert("Rename Workspace", isPresented: $renaming) {
            TextField("Name", text: $draftName)
            Button("Rename") { onRename(draftName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The branch keeps its name.")
        }
    }

    private func creatorHelp(_ creator: String) -> String {
        let line = "Created by the agent in \(creator)"
        return workspace.note.map { "\(line): \($0)" } ?? line
    }

    private func nameColor(isOpen: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.9) }
        return isOpen ? Color.primary : Color.secondary
    }
}

/// The └ that ties a stacked row to the row it sits on.
private struct StackElbow: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let x = size.width / 2
            path.move(to: CGPoint(x: x, y: -6))
            path.addLine(to: CGPoint(x: x, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 3, y: size.height / 2))
            context.stroke(path, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

/// What the workspace's chats are doing, most urgent first: waiting on
/// the user, working, or failed. Terminal tabs have no such signal.
private struct ChatActivityIndicator: View {
    let chats: [ChatSession]

    var body: some View {
        let activities = chats.map(\.activity)
        if activities.contains(.needsInput) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help("An agent is waiting for you")
        } else if activities.contains(.working) {
            ProgressView().controlSize(.mini)
                .help("An agent is working")
        } else if activities.contains(.failed) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        }
    }
}

/// PR-state glyph (Octicons PNG, tinted as a template) with an SF Symbol
/// check-status badge in the bottom-right. Dimensions are driven by `size`;
/// the badge ring matches the surrounding sidebar fill so it visually punches
/// out the underlying glyph stroke.
struct PRStatusIcon: View {
    let snapshot: PRSnapshot?
    var size: CGFloat = 16

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let kind = stateKind, let img = Self.image(kind) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .frame(width: size, height: size)
                    .foregroundStyle(stateColor(kind))
            } else {
                Color.clear.frame(width: size, height: size)
            }
            if let badge = checkBadge {
                Image(systemName: badge.symbol)
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(badge.color)
                    .background(
                        Circle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: size * 0.6, height: size * 0.6)
                    )
                    .offset(x: size * 0.18, y: size * 0.18)
            }
        }
        .frame(width: size, height: size)
    }

    private enum Kind { case open, draft, closed, noPR, pending }

    private var stateKind: Kind? {
        switch snapshot {
        // `nil` (no entry yet) and `.loading` (poll in flight) both render
        // the noPR silhouette at tertiary intensity — keeps the row from
        // going iconless and makes the transition to a real state a color
        // shift instead of a pop-in.
        case nil, .loading: return .pending
        case .error: return nil
        case .absent: return .noPR
        case let .loaded(pr, _):
            if pr.isDraft { return .draft }
            switch pr.state.uppercased() {
            case "OPEN":   return .open
            case "CLOSED": return .closed
            // Merged falls through to nil — workspace is expected to be
            // auto-deleted shortly after a merge is detected.
            default:       return nil
            }
        }
    }

    private func stateColor(_ kind: Kind) -> Color {
        switch kind {
        case .open:    return .readableGreen
        case .draft:   return .secondary
        case .closed:  return .red
        case .noPR:    return .secondary
        case .pending: return .secondary.opacity(0.5)
        }
    }

    private struct Badge { let symbol: String; let color: Color }

    /// Failing and in-flight checks take precedence — they're the states
    /// that want attention now. The green check is reserved for "approved",
    /// not "CI is green": a passing build on an unreviewed PR still has
    /// work left, so it gets no badge rather than a misleading tick.
    private var checkBadge: Badge? {
        guard case let .loaded(pr, checks) = snapshot else { return nil }
        var fail = 0, active = 0
        for run in checks {
            switch run.bucket {
            case .fail: fail += 1
            case .pass: break
            default:    if run.isActive { active += 1 }
            }
        }
        if fail > 0      { return Badge(symbol: "xmark.circle.fill",     color: .red) }
        if active > 0    { return Badge(symbol: "circle.fill",           color: .yellow) }
        if pr.isApproved { return Badge(symbol: "checkmark.circle.fill", color: .readableGreen) }
        return nil
    }

    private static func image(_ kind: Kind) -> NSImage? { cache[kind] }

    private static let cache: [Kind: NSImage] = {
        let names: [Kind: String] = [
            .open: "PRStateOpen",
            .draft: "PRStateDraft",
            .closed: "PRStateClosed",
            .noPR: "PRStateNone",
            .pending: "PRStateNone"
        ]
        return names.compactMapValues { Bundle.jetlineResources.templateImage($0) }
    }()
}
#endif
