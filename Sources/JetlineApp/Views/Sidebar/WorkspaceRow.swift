import SwiftUI
import AppKit

struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    var body: some View {
        // Inner view observes the per-workspace state directly so a poll
        // landing on a *different* workspace doesn't invalidate this row.
        WorkspaceRowContent(
            workspace: workspace,
            workspaceState: state.workspaceState(for: workspace.id),
            isSelected: state.selectedWorkspaceId == workspace.id,
            onArchive: { keepWorktree in
                Task { await state.archiveWorkspace(workspace, removeWorktree: !keepWorktree) }
            },
            onClose: { state.closeWorkspace(workspace.id) }
        )
    }
}

private struct WorkspaceRowContent: View {
    let workspace: Workspace
    let workspaceState: WorkspaceState
    let isSelected: Bool
    let onArchive: (_ keepWorktree: Bool) -> Void
    let onClose: () -> Void

    @State private var hovering = false

    var body: some View {
        let isOpen = !workspaceState.sessions.isEmpty
        HStack(spacing: 0) {
            PRStatusIcon(snapshot: workspaceState.pr, size: 13)
            Spacer().frame(width: 10)
            Text(workspace.name)
                .font(.body)
                .foregroundStyle(nameColor(isOpen: isOpen))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isOpen {
                CloseWorkspaceButton(visible: hovering, action: onClose)
            }
        }
        // 27.5 centers the 13pt PR icon on the repo favicon in the section
        // header above: the header's icon center sits at 4 (leading) + 12
        // (chevron) + 3 (gap) + 4 (label padding) + 11 (icon-slot center)
        // = 34pt from the shared content origin, and 27.5 + 6.5 = 34.
        .padding(.leading, 27.5)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .overlay(alignment: .leading) {
            OpenWorkspaceBar(isOpen: isOpen, isSelected: isSelected)
        }
        .accessibilityValue(isOpen ? "Open" : "")
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal worktree in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.worktreePath)])
            }
            if !workspaceState.sessions.isEmpty {
                Button("Close workspace") { onClose() }
            }
            Divider()
            Button("Archive (keep worktree)") { onArchive(true) }
            Button("Delete worktree…", role: .destructive) { onArchive(false) }
        }
    }

    private func nameColor(isOpen: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.9) }
        return isOpen ? Color.primary : Color.secondary
    }
}

/// Leading-edge state bar, the sidebar analog of the tab strip's active
/// accent bar: thin and grey while the workspace has open sessions,
/// slightly wider and accent-tinted when it's also the selection.
struct OpenWorkspaceBar: View {
    let isOpen: Bool
    let isSelected: Bool
    var height: CGFloat = 18

    var body: some View {
        if isOpen || isSelected {
            RoundedRectangle(cornerRadius: 1)
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                .frame(width: isSelected ? 3 : 2, height: height)
        }
    }
}

struct CloseWorkspaceButton: View {
    let visible: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(hovering ? 0.16 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(visible || hovering ? 1 : 0)
        .onHover { hovering = $0 }
        .help("Close workspace — ends its sessions")
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
            // auto-archived shortly after a merge is detected.
            default:       return nil
            }
        }
    }

    private func stateColor(_ kind: Kind) -> Color {
        switch kind {
        case .open:    return .green
        case .draft:   return .secondary
        case .closed:  return .red
        case .noPR:    return .secondary
        case .pending: return .secondary.opacity(0.5)
        }
    }

    private struct Badge { let symbol: String; let color: Color }

    private var checkBadge: Badge? {
        guard case let .loaded(_, checks) = snapshot, !checks.isEmpty else { return nil }
        var fail = 0, active = 0, pass = 0
        for run in checks {
            switch run.bucket {
            case .fail: fail += 1
            case .pass: pass += 1
            default:    if run.isActive { active += 1 }
            }
        }
        if fail > 0   { return Badge(symbol: "xmark.circle.fill",     color: .red) }
        if active > 0 { return Badge(symbol: "circle.fill",           color: .yellow) }
        if pass > 0   { return Badge(symbol: "checkmark.circle.fill", color: .green) }
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
        var map: [Kind: NSImage] = [:]
        for (kind, name) in names {
            if let url = Bundle.jetlineResources.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                map[kind] = img
            }
        }
        return map
    }()
}
