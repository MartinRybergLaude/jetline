import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text("Jetforge")
                .font(.system(size: 28, weight: .semibold))
            Text(state.repositories.isEmpty
                 ? "Add a git repository to get started."
                 : "Pick a workspace, or create a new one.")
                .foregroundStyle(.secondary)
            Button {
                Task { await state.addRepository() }
            } label: {
                Label("Add repository", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
