import SwiftUI

/// Live tail of the workspace's run-script output, hosted inside the
/// inspector. Replaces the previous modal sheet.
struct RunOutputPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let id = state.selectedWorkspaceId,
           let ws = state.workspaceById(id) {
            content(for: ws)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func content(for workspace: Workspace) -> some View {
        if !state.hasRunScript(workspace) {
            InspectorPlaceholder(
                systemImage: "play.slash",
                title: "No run script configured for this repository."
            )
        } else if let controller = state.runController(for: workspace.id) {
            RunOutputContent(controller: controller)
        } else {
            InspectorPlaceholder(
                systemImage: "play.circle",
                title: "Click the run button in the toolbar to start."
            )
        }
    }
}

private struct RunOutputContent: View {
    @ObservedObject var controller: RunController

    var body: some View {
        VStack(spacing: 0) {
            statusRow
            Divider()
            outputArea
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: controller.isRunning ? "circle.fill" : "circle")
                .foregroundStyle(controller.isRunning ? .green : .secondary)
                .font(.system(size: 8))
            Text(controller.isRunning ? "Running" : exitDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if controller.isRunning {
                Button("Stop") { controller.stop() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var outputArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(controller.output.isEmpty ? "(no output yet)" : controller.output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
                    .id("tail")
            }
            .onChange(of: controller.output) { _, _ in
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo("tail", anchor: .bottom)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var exitDescription: String {
        if let s = controller.exitStatus { return "Exited (\(s))" }
        return "Idle"
    }
}
