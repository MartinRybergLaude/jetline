import SwiftUI

/// "Import branch" tab of the workspace creation sheet. Defaults to recent
/// activity; full set is searched once the user types two or more characters
/// or flips the "Show all branches" toggle.
struct ImportBranchPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var branches: [BranchRow] = []
    @State private var refreshing: Bool = false
    @State private var search: String = ""
    @State private var showAll: Bool = false
    @State private var selectedRef: String?
    @State private var name: String = ""
    @State private var importing: Bool = false
    /// Archived workspaces for this repo, keyed by their local branch name.
    /// A row whose branch is in this dict renders the "Merged" badge and
    /// routes Import → `restoreOrImportWorkspace` instead of fresh import.
    @State private var archivedByBranch: [String: Workspace] = [:]

    private static let recentWindow: TimeInterval = 90 * 24 * 60 * 60

    private enum RowStatus {
        case fresh
        case merged
        case active

        var badgeText: String? {
            switch self {
            case .fresh:  return nil
            case .merged: return "Merged"
            case .active: return "Already imported"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                searchField
                Spacer(minLength: 4)
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh from remote")
                }
            }

            branchList

            if let ref = selectedRef, status(for: ref) == .fresh {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Workspace name").font(.caption).foregroundStyle(.secondary)
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(importButtonLabel) {
                    Task { await runImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canImport)
            }
        }
        .task { await refresh() }
        .onChange(of: selectedRef) { _, new in
            // Pre-fill the name field for the picked branch. Only meaningful
            // for `.fresh` rows (the field is hidden for `.merged` and the
            // Import button is disabled for `.active`).
            guard let new,
                  let row = branches.first(where: { $0.ref == new }) else { return }
            name = defaultName(for: row.ref)
        }
    }

    private var canImport: Bool {
        guard let ref = selectedRef, !importing else { return false }
        switch status(for: ref) {
        case .active: return false
        case .merged: return true
        case .fresh:  return !trimmedName.isEmpty
        }
    }

    private var importButtonLabel: String {
        if importing { return "Importing…" }
        if let ref = selectedRef, status(for: ref) == .merged { return "Restore" }
        return "Import"
    }

    /// Single-lookup form for spots outside the list. The list itself uses
    /// the `imported:` overload so the set is built once per render, not
    /// once per row.
    private func status(for ref: String) -> RowStatus {
        status(for: ref, imported: importedBranchNames)
    }

    private func status(for ref: String, imported: Set<String>) -> RowStatus {
        let local = repository.localName(forRemoteRef: ref)
        if imported.contains(local) { return .active }
        if archivedByBranch[local] != nil { return .merged }
        return .fresh
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search branches", text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var branchList: some View {
        let rows = filteredRows
        let imported = importedBranchNames
        return Group {
            if rows.isEmpty {
                emptyState
            } else {
                List(rows, selection: $selectedRef) { row in
                    branchRowView(row, status: status(for: row.ref, imported: imported))
                        .tag(row.ref)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollIndicators(.visible)
            }
        }
        .frame(minHeight: 260)
        .toggleStyle(.checkbox)
        .overlay(alignment: .bottomTrailing) {
            Toggle("Show all", isOn: $showAll)
                .controlSize(.small)
                .padding(8)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if refreshing {
                ProgressView()
                Text("Loading branches…").font(.caption).foregroundStyle(.secondary)
            } else if !branches.isEmpty {
                Text("No matches").font(.headline)
                Text("Try a different search or enable Show all.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No remote branches").font(.headline)
                Text("Nothing tracked under \(repository.remoteOrigin)/.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func branchRowView(_ row: BranchRow, status: RowStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.ref)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(status == .active ? .secondary : .primary)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let badgeText = status.badgeText {
                Text(badgeText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.vertical, 2)
        // Only `.active` rows are unselectable, so they're the only ones
        // that get dimmed. `.merged` rows look normal because clicking
        // them does something useful (restore).
        .opacity(status == .active ? 0.55 : 1)
        .contentShape(Rectangle())
    }

    private func defaultName(for ref: String) -> String {
        let stripped = repository.localName(forRemoteRef: ref)
        if let prefix = repository.branchPrefix?.nonBlank, stripped.hasPrefix(prefix) {
            return String(stripped.dropFirst(prefix.count))
        }
        return stripped
    }

    private var filteredRows: [BranchRow] {
        let trimmedSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        let defaultRefs = defaultBranchRefs

        return branches.filter { row in
            if defaultRefs.contains(row.ref) { return false }
            if !trimmedSearch.isEmpty {
                return row.ref.localizedCaseInsensitiveContains(trimmedSearch)
            }
            if showAll { return true }
            return row.lastCommitAt >= cutoff
        }
    }

    private var defaultBranchRefs: Set<String> {
        let local = repository.defaultBranch
        let remote = "\(repository.remoteOrigin)/\(local)"
        return [local, remote]
    }

    private var importedBranchNames: Set<String> {
        Set((state.workspacesByRepo[repository.id] ?? []).map(\.branchName))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refresh() async {
        refreshing = true
        defer { refreshing = false }
        // Archived rows first — synchronous, and independent of the remote
        // listing below. Rows are newest-first, so the most recently active
        // workspace wins if two archived rows share a branch.
        let archived = state.archivedWorkspaces(for: repository.id)
        archivedByBranch = Dictionary(
            archived.map { ($0.branchName, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let raw = await WorktreeOps.listRemoteBranches(
            repoPath: repository.path,
            remote: repository.remoteOrigin
        )
        branches = raw.map { BranchRow(ref: $0.ref, lastCommitAt: $0.lastCommitAt) }
    }

    private func runImport() async {
        guard let ref = selectedRef else { return }
        importing = true
        defer { importing = false }

        let local = repository.localName(forRemoteRef: ref)
        if let archived = archivedByBranch[local] {
            await state.restoreOrImportWorkspace(archived, in: repository)
        } else {
            await state.createWorkspaceFromBranch(
                in: repository,
                remoteRef: ref,
                name: trimmedName
            )
        }
        dismiss()
    }
}

private struct BranchRow: Hashable, Identifiable {
    let ref: String
    let lastCommitAt: Date
    var id: String { ref }

    var subtitle: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: lastCommitAt, relativeTo: Date())
    }
}
