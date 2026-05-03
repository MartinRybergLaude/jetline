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

    private static let recentWindow: TimeInterval = 90 * 24 * 60 * 60

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

            if selectedRef != nil {
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
                Button(importing ? "Importing…" : "Import") {
                    Task { await runImport() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRef == nil || trimmedName.isEmpty || importing)
            }
        }
        .task { await refresh() }
        .onChange(of: selectedRef) { _, new in
            guard let new else { return }
            if importedBranchNames.contains(repository.localName(forRemoteRef: new)) {
                selectedRef = nil
                return
            }
            if let row = branches.first(where: { $0.ref == new }) {
                name = defaultName(for: row.ref)
            }
        }
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
                    branchRowView(row, alreadyImported: imported.contains(repository.localName(forRemoteRef: row.ref)))
                        .tag(row.ref)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
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

    private func branchRowView(_ row: BranchRow, alreadyImported: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.ref)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(alreadyImported ? .secondary : .primary)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if alreadyImported {
                Text("Already imported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.vertical, 2)
        .opacity(alreadyImported ? 0.55 : 1)
        .contentShape(Rectangle())
    }

    private func defaultName(for ref: String) -> String {
        let stripped = repository.localName(forRemoteRef: ref)
        let candidates = [
            repository.branchPrefix?.nonBlank,
            state.settings.globalBranchPrefix.nonBlank
        ].compactMap { $0 }
        for candidate in candidates where stripped.hasPrefix(candidate) {
            return String(stripped.dropFirst(candidate.count))
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
        let raw = await WorktreeOps.listRemoteBranches(
            repoPath: repository.path,
            remote: repository.remoteOrigin
        )
        branches = raw.map { BranchRow(ref: $0.ref, lastCommitAt: $0.lastCommitAt) }
    }

    private func runImport() async {
        guard let ref = selectedRef else { return }
        importing = true
        await state.createWorkspaceFromBranch(
            in: repository,
            remoteRef: ref,
            name: trimmedName
        )
        importing = false
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
