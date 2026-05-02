import SwiftUI
import AppKit

struct WorkspaceRow: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace

    private var isSelected: Bool {
        state.selectedWorkspaceId == workspace.id
    }

    var body: some View {
        HStack(spacing: 10) {
            PRStatusIcon(snapshot: state.prByWorkspace[workspace.id], size: 13)
            Text(workspace.name)
                .font(.body)
                .foregroundStyle(isSelected ? Color.accentColor.opacity(0.9) : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, 28)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Reveal worktree in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: workspace.worktreePath)])
            }
            Divider()
            Button("Archive (keep worktree)") {
                Task { await state.archiveWorkspace(workspace, removeWorktree: false) }
            }
            Button("Delete worktree…", role: .destructive) {
                Task { await state.archiveWorkspace(workspace, removeWorktree: true) }
            }
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

    private enum Kind { case open, draft, closed, noPR }

    private var stateKind: Kind? {
        switch snapshot {
        case nil, .loading, .error: return nil
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
        case .open:   return .green
        case .draft:  return .secondary
        case .closed: return .red
        case .noPR:   return .secondary
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
        if active > 0 { return Badge(symbol: "circle.dotted",         color: .yellow) }
        if pass > 0   { return Badge(symbol: "checkmark.circle.fill", color: .green) }
        return nil
    }

    private static func image(_ kind: Kind) -> NSImage? { cache[kind] }

    private static let cache: [Kind: NSImage] = {
        let names: [Kind: String] = [
            .open: "PRStateOpen",
            .draft: "PRStateDraft",
            .closed: "PRStateClosed",
            .noPR: "PRStateNone"
        ]
        var map: [Kind: NSImage] = [:]
        for (kind, name) in names {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                map[kind] = img
            }
        }
        return map
    }()
}
