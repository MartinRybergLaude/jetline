import SwiftUI
import AppKit

struct PRPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Group {
            if let id = state.inspectorWorkspaceId,
               let ws = state.workspaceById(id) {
                PRPanelContent(
                    workspace: ws,
                    workspaceState: state.workspaceState(for: ws.id)
                )
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
}

private struct PRPanelContent: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    let workspaceState: WorkspaceState

    /// Owns its scrolling (unlike the changes panel, which `InspectorView`
    /// wraps) so the merge button can sit in a footer the checks list
    /// scrolls under, rather than being one more thing to scroll down to.
    var body: some View {
        ScrollView {
            content
                .padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
        .safeAreaInset(edge: .bottom, spacing: 0) { mergeFooter }
    }

    @ViewBuilder
    private var content: some View {
        switch workspaceState.pr {
        case .loading, .error, .absent:
            PRSnapshotPlaceholder(
                snapshot: workspaceState.pr,
                branchName: workspace.branchName
            )
        case let .loaded(pr, checks):
            VStack(alignment: .leading, spacing: 12) {
                PRHeaderCard(
                    pr: pr,
                    isRefreshing: workspaceState.isRefreshingPR,
                    onRefresh: {
                        state.requestPRRefresh(workspaceId: workspaceState.id)
                    }
                )
                ReviewSection(pr: pr)
                ChecksSection(checks: checks)
            }
            .padding(.horizontal, 12)
        }
    }

    @ViewBuilder
    private var mergeFooter: some View {
        if case let .loaded(pr, _) = workspaceState.pr,
           GitActionState.gitHubAllowsMerge(pr) {
            MergeSection(
                workspace: workspace,
                isMerging: workspaceState.runningGitAction == .mergePR
            )
        }
    }
}

/// Shown whenever GitHub would let you press Merge (see
/// `GitActionState.gitHubAllowsMerge`) — the same gate the toolbar's action
/// menu uses. Not a stricter one: if github.com offers the button, so do we,
/// and the checks list right above says whether that's a good idea.
///
/// Lives in the panel's bottom safe area as an opaque bar with a hairline
/// on top: the checks list scrolls *behind* it, so the merge affordance is
/// never something you have to scroll to find.
///
/// Split button, like GitHub's own: the wide half merges with the repo's
/// default strategy (last one used here, else the first it allows) and the
/// chevron offers the others. Repos that allow only one strategy get the
/// wide half alone. Both halves are plain Buttons — `Menu`, with or without
/// `primaryAction:`, renders as a system pull-down that ignores the glass
/// style, the tint and the height it's given — so the alternates come from a
/// popover the chevron opens.
///
/// Green rather than the accent tint the copy button uses: it's the
/// terminal, irreversible action in this panel, and shouldn't read as the
/// same weight of click as copying a link. The confirmation sheet is shared
/// with the toolbar's git action menu.
private struct MergeSection: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    let isMerging: Bool

    /// Set to the strategy the user picked, which both opens the
    /// confirmation and tells it what to confirm.
    @State private var pendingMethod: MergeMethod?
    @State private var isConfirming = false
    @State private var showingAlternates = false

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    Button { confirm(defaultMethod) } label: { label }
                        .buttonStyle(.glassProminent)
                        .tint(.readableGreen)
                        .disabled(isMerging || defaultMethod == nil)

                    if !isMerging, !alternates.isEmpty {
                        Button { showingAlternates.toggle() } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 12)
                                // Same trick as the header card's link
                                // button: a glyph-only label is shorter than
                                // a text one, so stretch to the row height
                                // the wide half sets.
                                .frame(maxHeight: .infinity)
                        }
                        // Untinted: the chevron only *picks* a strategy, and
                        // a second green button beside the first would read
                        // as two ways to merge rather than one.
                        .buttonStyle(.glass)
                        .frame(maxHeight: .infinity)
                        .help("Other merge strategies")
                        .popover(isPresented: $showingAlternates, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(alternates, id: \.self) { method in
                                    MergeMethodRow(method: method) {
                                        showingAlternates = false
                                        confirm(method)
                                    }
                                }
                            }
                            .padding(5)
                            .frame(minWidth: 180)
                        }
                    }
                }
                .controlSize(.regular)
                .fixedSize(horizontal: false, vertical: true)
                .help("Merge into \(workspace.baseBranch)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        // Opaque, so the checks list passes behind the bar rather than
        // showing through it — the buttons carry glass, but a floating glass
        // *bar* over scrolling text is where Liquid Glass stops being
        // legible.
        .background(Color(nsColor: .windowBackgroundColor))
        .mergeConfirmation(
            workspace: workspace,
            method: pendingMethod,
            isPresented: $isConfirming
        )
    }

    /// Names the strategy the primary tap will use, the way GitHub's button
    /// does — "Merge pull request" would hide which of three quite different
    /// things is about to happen to the history.
    private var label: some View {
        Label {
            Text(isMerging ? "Merging…" : (defaultMethod?.displayName ?? "Merge pull request"))
        } icon: {
            if isMerging {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.triangle.merge")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var methods: [MergeMethod] { state.allowedMergeMethods(for: workspace) }
    private var defaultMethod: MergeMethod? { state.defaultMergeMethod(for: workspace) }
    private var alternates: [MergeMethod] { methods.filter { $0 != defaultMethod } }

    private func confirm(_ method: MergeMethod?) {
        guard let method else { return }
        pendingMethod = method
        isConfirming = true
    }
}

/// One alternate strategy in the chevron's popover. Hand-rolled hover
/// highlight because a popover isn't a menu: `.buttonStyle(.plain)` gives no
/// feedback at all, and the bordered styles would stack three buttons'
/// worth of chrome inside an already-floating panel.
private struct MergeMethodRow: View {
    let method: MergeMethod
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(method.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    isHovering ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// Filled capsule carrying a glyph + one word of status. Used for the PR's
/// own state and for the review gate, so the two read as the same kind of
/// fact at a glance.
///
/// Sentence case rather than the shouty all-caps badge this replaced: the
/// glyph already carries the emphasis, and at 10pt caps are the harder of
/// the two to read. Green chips take `readableGreen` so they match the green
/// used by the check marks right below them — system green next to it reads
/// as a second, brighter green rather than the same status.
struct StatusChip: View {
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text(label)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color, in: Capsule())
    }
}

/// The panel's anchor: identity (state, number, title), where the change is
/// going, and the two things you actually do with a PR from here. Copying the
/// URL is the primary action — it's what a PR gets pasted into a chat or an
/// agent prompt with — so per the HIG it's the one filled button on screen,
/// and everything secondary (opening on github.com, refreshing) stays quiet
/// beside it.
private struct PRHeaderCard: View {
    let pr: PullRequest
    let isRefreshing: Bool
    let onRefresh: () -> Void

    /// Flipped for a beat after a copy so the button confirms in place
    /// rather than needing a separate status line. Mirrors the run output
    /// panel's copy affordance.
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identityRow
            Text(pr.title)
                .font(.headline)
                .lineLimit(3)
                // Headlines wrap in a 240pt-wide inspector; without this the
                // card claims a single line's height and clips.
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            metadata
            actions
        }
        .padding(12)
        .cardSurface(
            fill: Color.secondary.opacity(0.08),
            stroke: Color.secondary.opacity(0.18)
        )
    }

    private var identityRow: some View {
        HStack(spacing: 6) {
            statePill
            Text("#\(pr.number)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            RefreshButton(isRefreshing: isRefreshing, help: "Refresh pull request") {
                onRefresh()
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                Text("\(pr.headRefName) → \(pr.baseRefName)")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)

            Text(byline)
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasConflicts {
                Label("Merge conflicts with \(pr.baseRefName)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
    }

    /// Glass, like the sidebar's footer buttons — the two are the app's only
    /// pair of "act on this thing" controls, so they should feel the same.
    /// The copy button takes the *prominent* glass (accent tint) because it's
    /// the primary action; the `GlassEffectContainer` lets the two capsules
    /// share one lensing pass instead of refracting each other.
    private var actions: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    copyURL()
                } label: {
                    Label(didCopy ? "Copied" : "Copy URL",
                          systemImage: didCopy ? "checkmark" : "link")
                        // The prominent button takes the row's slack, so its
                        // own width doesn't change when the label flips to
                        // "Copied".
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .help("Copy the pull request URL")

                Button {
                    if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .frame(width: 14)
                        // A glyph-only label is shorter than a text one, so
                        // this button stretches to the row's height (set by
                        // the prominent button beside it) rather than sizing
                        // itself.
                        .frame(maxHeight: .infinity)
                }
                .buttonStyle(.glass)
                .frame(maxHeight: .infinity)
                .help("Open on GitHub")
            }
            .controlSize(.regular)
            // The row is only as tall as the prominent button wants to be —
            // without this the `maxHeight` above would chase the whole card.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var byline: String {
        var parts = ["@\(pr.author.login)"]
        if let date = pr.mergedAt {
            parts.append("merged \(Self.relative(date))")
        } else if let date = pr.createdAt {
            parts.append("opened \(Self.relative(date))")
        }
        return parts.joined(separator: " · ")
    }

    /// `mergeable` is the authoritative field; `mergeStateStatus` catches the
    /// `DIRTY` case gh reports while it recomputes mergeability.
    private var hasConflicts: Bool {
        pr.mergeable?.uppercased() == "CONFLICTING"
            || pr.mergeStateStatus?.uppercased() == "DIRTY"
    }

    private func copyURL() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(pr.url, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var statePill: some View {
        let (label, symbol, color): (String, String, Color) = {
            if pr.isDraft { return ("Draft", "arrow.triangle.pull", .gray) }
            switch pr.state.uppercased() {
            case "OPEN":   return ("Open", "arrow.triangle.pull", .readableGreen)
            case "MERGED": return ("Merged", "arrow.triangle.merge", .purple)
            case "CLOSED": return ("Closed", "xmark", .red)
            default:       return (pr.state.capitalized, "questionmark", .secondary)
            }
        }()
        return StatusChip(label: label, symbol: symbol, color: color)
    }
}

/// Approval state, laid out like `ChecksSection`'s header so the two read
/// as one column of gates. Mirrors the sidebar badge: the green checkmark
/// means approved, not "CI is green".
private struct ReviewSection: View {
    let pr: PullRequest

    var body: some View {
        HStack(spacing: 6) {
            Text("Review")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            StatusChip(label: label, symbol: symbol, color: color)
        }
    }

    private var symbol: String {
        switch pr.reviewState {
        case .approved:         return "checkmark"
        case .changesRequested: return "xmark"
        case .reviewRequired:   return "clock"
        case .unreviewed:       return "minus"
        }
    }

    private var color: Color {
        switch pr.reviewState {
        case .approved:         return .readableGreen
        case .changesRequested: return .red
        // Orange, not the yellow used for the check icons: yellow can't
        // carry the chip's white label.
        case .reviewRequired:   return .orange
        case .unreviewed:       return .gray
        }
    }

    private var label: String {
        switch pr.reviewState {
        case .approved:         return "Approved"
        case .changesRequested: return "Changes requested"
        case .reviewRequired:   return "Review required"
        case .unreviewed:       return "Not reviewed"
        }
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

/// Filled yellow dot that fades in and out — visual match for the
/// "in-progress" check state. Matches the sizing of the other SF Symbol
/// check icons by reusing `circle.fill` instead of a raw Circle shape.
///
/// `symbolEffect` rather than an `.animation` modifier with
/// `repeatForever`: the latter keeps an implicit animation transaction
/// open continuously, which causes incidental layout changes (rows
/// reordering when GitHub returns checks in a different order between
/// polls) to interpolate smoothly — so running dots visibly drift up
/// and down on each poll.
private struct PulsingCheckIcon: View {
    var body: some View {
        Image(systemName: "circle.fill")
            .foregroundStyle(.yellow)
            .symbolEffect(.pulse, options: .repeating)
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
            if let link = run.link {
                OpenOnGitHubButton(url: link, help: "Open check on GitHub")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch visual {
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.readableGreen)
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.yellow)
        case .running:
            PulsingCheckIcon()
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
