import SwiftUI
import AppKit

/// Live tail of the workspace's run-script output, hosted inside the
/// inspector. Renders through libghostty so chatty TUIs (vite, jest watchers)
/// don't bog the panel down.
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
    @State private var copyFeedback = false

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
            Button {
                if controller.copyOutputToPasteboard() {
                    showCopyFeedback()
                }
            } label: {
                Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Copy run output")
            if controller.isRunning {
                Button("Stop") { controller.stop() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var outputArea: some View {
        if let emulator = controller.emulator {
            RunTerminalHost(emulator: emulator)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
            // First mount before any run started.
            VStack {
                Spacer()
                Text("(no output yet)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var exitDescription: String {
        if let s = controller.exitStatus { return "Exited (\(s))" }
        return "Idle"
    }

    private func showCopyFeedback() {
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copyFeedback = false
        }
    }
}

/// SwiftUI ↔ AppKit bridge for the run output's terminal. The emulator
/// itself is owned by `RunController` and outlives this host — when the
/// panel is dismounted (Run tab deselected, inspector hidden) we reparent
/// the underlying NSView away so the next mount can adopt it again.
private struct RunTerminalHost: NSViewRepresentable {
    let emulator: TerminalEmulatorView

    final class Coordinator {
        weak var emulator: AnyObject?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.emulator = emulator as AnyObject
        attach(emulator.nsView, to: container)
        emulator.setActive(true)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let term = emulator.nsView
        if term.superview !== nsView {
            for sub in nsView.subviews { sub.removeFromSuperview() }
            attach(term, to: nsView)
        }
        context.coordinator.emulator = emulator as AnyObject
        emulator.setActive(true)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Pause the GPU surface when the panel goes away. The emulator
        // outlives the host (RunController owns it), so we don't terminate.
        if let emulator = coordinator.emulator as? TerminalEmulatorView {
            MainActor.assumeIsolated {
                emulator.setActive(false)
            }
        }
        for sub in nsView.subviews { sub.removeFromSuperview() }
    }

    private func attach(_ term: NSView, to container: NSView) {
        term.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(term)
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
}
