import SwiftUI

/// "Import PR" tab of the workspace creation sheet. Lists open PRs from the
/// same repo (forks excluded for v1). Selecting a row reveals an editable
/// name field pre-filled with a sanitized PR title.
struct ImportPRPane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository

    @State private var fetchState: FetchState = .loading
    @State private var search: String = ""
    @State private var selectedNumber: Int?
    @State private var name: String = ""
    @State private var importing: Bool = false

    enum FetchState {
        case loading
        case loaded([PRSummary])
        case authRequired
        case ghMissing
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                searchField
                Spacer(minLength: 4)
                if case .loading = fetchState {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh from GitHub")
                }
            }

            content
                .frame(minHeight: 280)

            if selectedNumber != nil {
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
                .disabled(selectedNumber == nil || trimmedName.isEmpty || importing)
            }
        }
        .task { await refresh() }
        .onChange(of: selectedNumber) { _, new in
            guard let new, case let .loaded(prs) = fetchState,
                  let pr = prs.first(where: { $0.number == new }) else { return }
            if importedBranchNames.contains(pr.headRefName) {
                selectedNumber = nil
                return
            }
            name = defaultName(for: pr)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Filter by title, number, author, or branch", text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch fetchState {
        case .loading:
            VStack(spacing: 6) {
                ProgressView()
                Text("Fetching open pull requests…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .loaded(prs):
            let filtered = filtered(prs)
            let imported = importedBranchNames
            if filtered.isEmpty {
                emptyState(showingFiltered: !prs.isEmpty)
            } else {
                List(filtered, selection: $selectedNumber) { pr in
                    prRow(pr, alreadyImported: imported.contains(pr.headRefName))
                        .tag(pr.number)
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }

        case .authRequired:
            inlineMessage(
                title: "GitHub auth required",
                detail: "Run `gh auth login` in a terminal, then refresh."
            )

        case .ghMissing:
            inlineMessage(
                title: "gh CLI not found",
                detail: "Install via `brew install gh`, then refresh."
            )

        case let .failed(msg):
            inlineMessage(title: "Couldn't fetch pull requests", detail: msg)
        }
    }

    private func emptyState(showingFiltered: Bool) -> some View {
        VStack(spacing: 6) {
            Text(showingFiltered ? "No matches" : "No open pull requests")
                .font(.headline)
            if showingFiltered {
                Text("Try a different search.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func inlineMessage(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Refresh") { Task { await refresh() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func prRow(_ pr: PRSummary, alreadyImported: Bool) -> some View {
        HStack(spacing: 10) {
            if let bucket = pr.checkBucket {
                Image(systemName: glyph(for: bucket))
                    .foregroundStyle(color(for: bucket))
                    .frame(width: 16)
            } else {
                Spacer().frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(pr.number)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(alreadyImported ? .secondary : .primary)
                    if pr.isDraft {
                        Text("Draft")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text("\(pr.authorLogin) · \(pr.headRefName) · \(relative(pr.updatedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if alreadyImported {
                Text("Already imported")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
        }
        .padding(.vertical, 2)
        .opacity(alreadyImported ? 0.55 : 1)
        .contentShape(Rectangle())
    }

    private func defaultName(for pr: PRSummary) -> String {
        let trimmed = pr.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(80))
    }

    private func filtered(_ prs: [PRSummary]) -> [PRSummary] {
        let identifier = state.repoMetadataByRepo[repository.id]
        let nonForks = identifier.map { id in prs.filter { !$0.isFork(of: id) } } ?? prs
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nonForks }
        return nonForks.filter { pr in
            "\(pr.number)".contains(q)
                || pr.title.localizedCaseInsensitiveContains(q)
                || pr.authorLogin.localizedCaseInsensitiveContains(q)
                || pr.headRefName.localizedCaseInsensitiveContains(q)
        }
    }

    private var importedBranchNames: Set<String> {
        Set((state.workspacesByRepo[repository.id] ?? []).map(\.branchName))
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func glyph(for bucket: CheckBucket) -> String {
        switch bucket {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .pending: return "circle.dotted"
        case .cancel, .skipping, .unknown: return "circle"
        }
    }

    private func color(for bucket: CheckBucket) -> Color {
        switch bucket {
        case .pass: return .green
        case .fail: return .red
        case .pending: return .yellow
        case .cancel, .skipping, .unknown: return .secondary
        }
    }

    private func refresh() async {
        fetchState = .loading
        let identifier: RepoIdentifier
        if let cached = state.repoMetadataByRepo[repository.id] {
            identifier = cached
        } else {
            do {
                guard let resolved = try await GitHubRunner.repoIdentifier(cwd: repository.path) else {
                    fetchState = .failed("Repository has no GitHub remote.")
                    return
                }
                identifier = resolved
            } catch GitHubRunner.Error.ghMissing {
                fetchState = .ghMissing
                return
            } catch GitHubRunner.Error.authRequired {
                fetchState = .authRequired
                return
            } catch {
                fetchState = .failed(error.localizedDescription)
                return
            }
            state.applyRepoMetadata(identifier, for: repository.id)
        }

        do {
            let prs = try await GitHubRunner.listOpenPRs(repo: identifier, cwd: repository.path)
            fetchState = .loaded(prs)
        } catch GitHubRunner.Error.ghMissing {
            fetchState = .ghMissing
        } catch GitHubRunner.Error.authRequired {
            fetchState = .authRequired
        } catch {
            fetchState = .failed(error.localizedDescription)
        }
    }

    private func runImport() async {
        guard let number = selectedNumber,
              case let .loaded(prs) = fetchState,
              let pr = prs.first(where: { $0.number == number }) else { return }
        importing = true
        await state.createWorkspaceFromPR(
            in: repository,
            pr: pr,
            name: trimmedName
        )
        importing = false
        dismiss()
    }
}
