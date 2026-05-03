import SwiftUI

/// "New" tab of the workspace creation sheet: derive a fresh feature branch
/// off the repo's default branch.
struct NewWorkspacePane: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    @State private var name: String = ""
    @State private var creating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. fix-auth-bug", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Base branch").font(.caption).foregroundStyle(.secondary)
                Text(repository.defaultBranch).font(.system(.body, design: .monospaced))
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create") {
                    creating = true
                    Task {
                        await state.createWorkspace(in: repository, name: trimmedName)
                        creating = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || creating)
            }
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
