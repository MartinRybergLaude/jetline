import SwiftUI

struct NewWorkspaceSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let repository: Repository
    @State private var name: String = ""
    @State private var agent: Workspace.AgentKind = .claude
    @State private var creating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New workspace in \(repository.name)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. fix-auth-bug", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $agent) {
                    ForEach(Workspace.AgentKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                        await state.createWorkspace(in: repository, name: trimmedName, agent: agent)
                        creating = false
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || creating)
            }
        }
        .padding(20)
        .frame(width: 400, height: 280)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
