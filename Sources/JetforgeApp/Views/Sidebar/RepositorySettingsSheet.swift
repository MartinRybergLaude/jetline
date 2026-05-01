import SwiftUI

/// Per-repository configuration sheet. Edits are kept in a local draft so
/// the user can cancel out without persisting; saving writes through
/// `AppState.updateRepository` and refreshes the in-memory repo list.
struct RepositorySettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    @State private var draft: Repository
    @State private var remotes: [String] = []
    @State private var baseRefs: [String] = []
    @State private var loadingRefs = true
    @State private var confirmingDelete = false

    init(repository: Repository) {
        self.repository = repository
        _draft = State(initialValue: repository)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Form {
                    repoIdentitySection
                    branchingSection
                    scriptsSection
                    dangerZoneSection
                }
                .formStyle(.grouped)
            }
            footer
        }
        .frame(width: 640, height: 720)
        .task { await loadRefs() }
        .confirmationDialog(
            "Delete \(repository.name)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete repository", role: .destructive) {
                state.removeRepository(repository.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This forgets the repo from Jetforge and tears down its workspaces' worktrees. The original git checkout at \(repository.path) is left alone.")
        }
    }

    // MARK: - Sections

    private var repoIdentitySection: some View {
        Section {
            LabeledContent("Path") {
                Text(repository.path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            TextField("Display name", text: $draft.name)
        } header: {
            Text("Repository")
        }
    }

    private var branchingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remote origin").font(.headline)
                Text("Where should we push, pull, and create PRs?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $draft.remoteOrigin) {
                    if remotes.isEmpty {
                        Text(draft.remoteOrigin).tag(draft.remoteOrigin)
                    } else {
                        ForEach(remotes, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                .disabled(loadingRefs)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Branch new workspaces from").font(.headline)
                Text("Each workspace is an isolated copy of your codebase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: $draft.defaultBranch) {
                    if baseRefs.isEmpty {
                        Text(draft.defaultBranch).tag(draft.defaultBranch)
                    } else {
                        ForEach(baseRefs, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                .disabled(loadingRefs)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Branch prefix").font(.headline)
                Text("Leave empty to inherit the global prefix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    state.settings.globalBranchPrefix,
                    text: Binding(
                        get: { draft.branchPrefix ?? "" },
                        set: { draft.branchPrefix = $0.isEmpty ? nil : $0 }
                    )
                )
            }
        }
    }

    private var scriptsSection: some View {
        Section {
            scriptEditor(
                title: "Setup script",
                help: "Runs once after a worktree is created. `$JETFORGE_ROOT_PATH` points at the original repo so you can copy or symlink files like .env.",
                placeholder: "pnpm install && ln -s \"$JETFORGE_ROOT_PATH/apps/web/.env\" apps/web/.env",
                text: Binding(
                    get: { draft.setupScript ?? "" },
                    set: { draft.setupScript = $0.isEmpty ? nil : $0 }
                )
            )
            scriptEditor(
                title: "Run script",
                help: "Runs when you press Run. `$JETFORGE_ROOT_PATH` is also available.",
                placeholder: "npm run dev",
                text: Binding(
                    get: { draft.runScript ?? "" },
                    set: { draft.runScript = $0.isEmpty ? nil : $0 }
                )
            )
            Toggle(isOn: $draft.runExclusive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Exclusive")
                    Text("Only one workspace in this repo can run at a time. Starting another stops the previous run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            scriptEditor(
                title: "Archive script",
                help: "Runs when a workspace is deleted, before git removes the worktree. Use it to clean up build artefacts.",
                placeholder: "rm -rf node_modules",
                text: Binding(
                    get: { draft.archiveScript ?? "" },
                    set: { draft.archiveScript = $0.isEmpty ? nil : $0 }
                )
            )
        } header: {
            Text("Scripts")
        }
    }

    private var dangerZoneSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete repository").font(.headline)
                    Text("Removes Jetforge's record and all its worktrees. The original checkout is untouched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Delete…", role: .destructive) {
                    confirmingDelete = true
                }
            }
        } header: {
            Text("Danger zone")
        }
    }

    private func scriptEditor(
        title: String,
        help: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 64, maxHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .background(
                    Group {
                        if text.wrappedValue.isEmpty {
                            Text(placeholder)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .allowsHitTesting(false)
                        }
                    }
                )
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                state.updateRepository(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(.bar)
    }

    // MARK: - Loaders

    private func loadRefs() async {
        async let r = WorktreeOps.listRemotes(at: repository.path)
        async let b = WorktreeOps.listBaseRefs(at: repository.path)
        let (remotes, refs) = await (r, b)
        self.remotes = remotes.isEmpty ? [draft.remoteOrigin] : remotes
        self.baseRefs = refs.contains(draft.defaultBranch) ? refs : ([draft.defaultBranch] + refs)
        self.loadingRefs = false
    }
}
