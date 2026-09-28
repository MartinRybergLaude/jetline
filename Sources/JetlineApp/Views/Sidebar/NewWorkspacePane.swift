#if os(macOS)
import SwiftUI

/// "New" tab of the workspace creation sheet: derive a fresh feature branch
/// off the repo's default branch, or stack it on another workspace's branch.
struct NewWorkspacePane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    var initialBaseWorkspaceId: String?
    @State private var name: String = ""
    @State private var creating: Bool = false
    /// `nil` is the default branch.
    @State private var baseWorkspaceId: String?

    var body: some View {
        let stackable = self.stackable
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. fix-auth-bug", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base").font(.caption).foregroundStyle(.secondary)
                if stackable.isEmpty {
                    Text(repository.defaultBranch).monoFont(.body)
                } else {
                    Picker("Base", selection: $baseWorkspaceId) {
                        Text(repository.defaultBranch).tag(String?.none)
                        Divider()
                        ForEach(stackable) { ws in
                            Text("\(ws.name) · \(ws.branchName)").tag(Optional(ws.id))
                        }
                    }
                    .labelsHidden()
                    // Not `fixedSize`: a menu picker's ideal width is its
                    // longest item, which pushed the whole sheet wider than
                    // its window and clipped both edges.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let base = stackable.first(where: { $0.id == baseWorkspaceId }) {
                        Text("Stacked on \(base.name): the branch starts from \(base.branchName) and its pull request targets it. Once both have PRs, they become a stack on GitHub.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create") {
                    creating = true
                    Task {
                        await state.createWorkspace(in: repository, name: trimmedName, baseWorkspaceId: baseWorkspaceId)
                        creating = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || creating)
            }
        }
        .onAppear { baseWorkspaceId = initialBaseWorkspaceId }
    }

    /// Workspaces a new one can stack on, in sidebar order.
    private var stackable: [Workspace] {
        WorkspaceStacks.sidebarOrder(state.workspacesByRepo[repository.id] ?? [], repo: repository)
            .map(\.workspace)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
