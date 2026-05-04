import SwiftUI

/// Per-repository configuration sheet. Edits are kept in a local draft so
/// the user can cancel out without persisting.
struct RepositorySettingsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    @State private var draft: Repository
    @State private var remotes: [String] = []
    @State private var baseRefs: [String] = []
    @State private var confirmingDelete = false
    /// Slugged `git config user.name`, loaded once per sheet open so the
    /// branch-prefix preview can show the live value the workspace creator
    /// will pick up.
    @State private var usernameSlug: String = ""

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
                    gitActionsSection
                    dangerZoneSection
                }
                .formStyle(.grouped)
            }
            footer
        }
        .frame(width: 580, height: 680)
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
            Text("This forgets the repo from Jetline and tears down its workspaces' worktrees. The original git checkout at \(repository.path) is left alone.")
        }
    }

    // MARK: - Sections

    private var repoIdentitySection: some View {
        Section {
            LabeledContent("Path") {
                Text(repository.path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            LabeledContent("Display name") {
                TextField("", text: $draft.name)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
            }
        } header: {
            Text("Repository")
        }
    }

    private var branchingSection: some View {
        Section {
            describedRow(
                title: "Remote origin",
                description: "Where Jetline pushes, pulls, and opens pull requests."
            ) {
                Picker("", selection: $draft.remoteOrigin) {
                    if remotes.isEmpty {
                        Text(draft.remoteOrigin).tag(draft.remoteOrigin)
                    } else {
                        ForEach(remotes, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            describedRow(
                title: "Branch new workspaces from",
                description: "Each workspace is an isolated copy of your codebase."
            ) {
                Picker("", selection: $draft.defaultBranch) {
                    if baseRefs.isEmpty {
                        Text(draft.defaultBranch).tag(draft.defaultBranch)
                    } else {
                        ForEach(baseRefs, id: \.self) { Text($0).tag($0) }
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            branchPrefixRow
        } header: {
            Text("Branching")
        }
    }

    private var branchPrefixRow: some View {
        BranchPrefixField(
            mode: branchPrefixModeBinding,
            customValue: branchPrefixCustomBinding,
            usernameSlug: usernameSlug
        )
    }

    private var branchPrefixModeBinding: Binding<BranchPrefixMode> {
        Binding(
            get: {
                if let raw = draft.branchPrefixMode, let mode = BranchPrefixMode(rawValue: raw) {
                    return mode
                }
                // Migrate-on-display: legacy rows with a non-empty custom
                // value land on `.custom`; everything else defaults to the
                // new `.username` behaviour.
                return draft.branchPrefix?.nonBlank == nil ? .username : .custom
            },
            set: { newMode in
                draft.branchPrefixMode = newMode.rawValue
                if newMode != .custom {
                    // Clear the legacy custom string so a later switch back
                    // to .custom starts from an explicit blank rather than
                    // a value the user didn't type in this session.
                    draft.branchPrefix = nil
                }
            }
        )
    }

    private var branchPrefixCustomBinding: Binding<String> {
        Binding(
            get: { draft.branchPrefix ?? "" },
            set: { draft.branchPrefix = $0.isEmpty ? nil : $0 }
        )
    }

    private var scriptsSection: some View {
        Section {
            scriptEditor(
                title: "Setup script",
                help: "Runs once after a worktree is created. `$\(ScriptRunner.rootPathEnvKey)` points at the original repo so you can copy or symlink files like .env.",
                placeholder: "pnpm install && ln -s \"$\(ScriptRunner.rootPathEnvKey)/apps/web/.env\" apps/web/.env",
                text: Binding(
                    get: { draft.setupScript ?? "" },
                    set: { draft.setupScript = $0.isEmpty ? nil : $0 }
                )
            )
            scriptEditor(
                title: "Run script",
                help: "Runs when you press Run. `$\(ScriptRunner.rootPathEnvKey)` is also available.",
                placeholder: "npm run dev",
                text: Binding(
                    get: { draft.runScript ?? "" },
                    set: { draft.runScript = $0.isEmpty ? nil : $0 }
                )
            )
            describedRow(
                title: "Exclusive run",
                description: "Only one workspace in this repo can run at a time. Starting another stops the previous run."
            ) {
                Toggle("", isOn: $draft.runExclusive).labelsHidden()
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

    /// Per-repo prompt overrides for the inspector's git action bar. Each
    /// editor's placeholder shows the *resolved global* prompt (global
    /// override → built-in default), so an empty field clearly inherits
    /// from the next layer up.
    private var gitActionsSection: some View {
        Section {
            ForEach(GitAction.promptable, id: \.self) { action in
                if let keyPath = action.repositoryKeyPath {
                    PromptOverrideEditor(
                        action: action,
                        binding: bindingPrompt(for: keyPath),
                        placeholderOverride: state.settings.prompt(for: action)?.nonBlank
                    )
                }
            }
        } header: {
            Text("Git action prompts")
        } footer: {
            Text("Empty fields inherit from the global prompt set in Settings → Git Actions.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func bindingPrompt(for keyPath: WritableKeyPath<Repository, String?>) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.nonBlank }
        )
    }

    private var dangerZoneSection: some View {
        Section {
            // Custom row layout (rather than `describedRow`) so the button
            // sits centred against the multi-line label instead of baseline-
            // aligned with the title alone, and tints to the destructive
            // accent — `role: .destructive` alone doesn't colourise plain
            // bordered buttons on macOS.
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Delete repository")
                    Text("Removes Jetline's record and all its worktrees. The original checkout is untouched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Delete…", role: .destructive) {
                    confirmingDelete = true
                }
                .tint(.red)
            }
        }
    }

    // MARK: - Building blocks

    private func describedRow<Control: View>(
        title: String,
        description: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func scriptEditor(
        title: String,
        help: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(.init(help))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .frame(minHeight: 64, maxHeight: 96)
                if text.wrappedValue.isEmpty {
                    // Matches the TextEditor's actual content origin: outer
                    // `.padding(6)` + the underlying NSTextView's default
                    // textContainerInset (zero on macOS 15+), so the
                    // placeholder lines up with where the user types.
                    Text(placeholder)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }
            }
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
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Loaders

    private func loadRefs() async {
        async let r = WorktreeOps.listRemotes(at: repository.path)
        async let b = WorktreeOps.listBaseRefs(at: repository.path)
        async let u = WorktreeOps.usernameSlug(at: repository.path)
        let (remotes, refs, slug) = await (r, b, u)
        self.remotes = remotes.isEmpty ? [draft.remoteOrigin] : remotes
        self.baseRefs = refs.contains(draft.defaultBranch) ? refs : ([draft.defaultBranch] + refs)
        self.usernameSlug = slug
    }
}

/// Three-mode picker for the branch prefix: derive from the user's git
/// identity, a hand-typed custom prefix, or no prefix at all. A live
/// preview of the resulting branch name sits at the right edge so the
/// formatting impact of each choice is immediate.
private struct BranchPrefixField: View {
    @Binding var mode: BranchPrefixMode
    @Binding var customValue: String
    let usernameSlug: String

    /// Workspace name used in the preview only. A short, plausible English
    /// noun reads more naturally than "<workspace-name>" or `slug` and
    /// matches the design reference image.
    private let exampleSlug = "tokyo"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Branch prefix")
                    Text("Prefix added to branch names when creating new workspaces in this repo.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("Preview:")
                        .foregroundStyle(.secondary)
                    Text(previewBranch)
                        .font(.system(.body, design: .monospaced))
                }
            }

            Picker(selection: $mode) {
                Text("Username").tag(BranchPrefixMode.username)
                Text("Custom").tag(BranchPrefixMode.custom)
                Text("None").tag(BranchPrefixMode.none)
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if mode == .custom {
                TextField("Custom prefix (e.g. team/)", text: $customValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
    }

    private var previewBranch: String {
        let prefix: String = {
            switch mode {
            case .username:
                return usernameSlug.isEmpty ? "" : usernameSlug + "/"
            case .custom:
                return customValue
            case .none:
                return ""
            }
        }()
        return prefix + exampleSlug
    }
}
