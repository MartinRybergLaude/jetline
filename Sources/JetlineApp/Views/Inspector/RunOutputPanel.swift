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

    /// Run output wins while the script is running; once it exits we drop
    /// back to the placeholder so the user sees the same clean slate as on
    /// a fresh workspace instead of staring at a stale exit trace. Setup
    /// output stays visible until the user triggers their first run (which
    /// discards the setup controller).
    @ViewBuilder
    private func content(for workspace: Workspace) -> some View {
        if let runController = state.runController(for: workspace.id),
           runController.isRunning {
            RunOutputContent(controller: runController)
        } else if let setupController = state.setupController(for: workspace.id) {
            SetupOutputContent(controller: setupController)
        } else if !state.hasRunScript(workspace) {
            InspectorPlaceholder(
                systemImage: "play.slash",
                title: "No run script configured for this repository."
            )
        } else {
            InspectorPlaceholder(
                systemImage: "play.circle",
                title: "Click the run button in the toolbar to start."
            )
        }
    }
}

/// Status strip + emulator (or empty-state) shared by run + setup panels.
/// The two panels diverged only in the strip's leading icon and label
/// strings, so everything else lives here.
private struct OutputShell<Status: View>: View {
    let emulator: TerminalEmulatorView?
    let copyHelp: String
    let copyAction: () -> Bool
    @ViewBuilder var status: () -> Status

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
            status()
            Spacer()
            Button {
                if copyAction() { showCopyFeedback() }
            } label: {
                // Fixed frame: `checkmark` and `doc.on.doc` have different
                // intrinsic heights at the same point size, otherwise the
                // strip jiggles when feedback flashes.
                Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(copyHelp)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var outputArea: some View {
        if let emulator {
            RunTerminalHost(emulator: emulator)
                .background(Color(nsColor: .textBackgroundColor))
        } else {
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

    private func showCopyFeedback() {
        copyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            copyFeedback = false
        }
    }
}

private struct SetupOutputContent: View {
    @ObservedObject var controller: SetupController

    var body: some View {
        OutputShell(
            emulator: controller.emulator,
            copyHelp: "Copy setup output",
            copyAction: controller.copyOutputToPasteboard
        ) {
            statusIcon
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if controller.isRunning {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.7)
                .frame(width: 10, height: 10)
        } else {
            Image(systemName: controller.didSucceed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(controller.didSucceed ? .green : .orange)
                .font(.system(size: 10))
        }
    }

    private var statusLabel: String {
        if controller.isRunning { return "Setting up…" }
        if controller.didSucceed { return "Setup complete" }
        if let code = controller.exitCode { return "Setup failed (\(code))" }
        return "Setup finished"
    }
}

private struct RunOutputContent: View {
    @ObservedObject var controller: RunController

    var body: some View {
        OutputShell(
            emulator: controller.emulator,
            copyHelp: "Copy run output",
            copyAction: controller.copyOutputToPasteboard
        ) {
            Image(systemName: controller.isRunning ? "circle.fill" : "circle")
                .foregroundStyle(controller.isRunning ? .green : .secondary)
                .font(.system(size: 8))
            Text(controller.isRunning ? "Running" : exitDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var exitDescription: String {
        if let s = controller.exitStatus { return "Exited (\(s))" }
        return "Idle"
    }
}

/// SwiftUI ↔ AppKit bridge for the run output's terminal. The emulator is
/// owned by `RunController` and lives in `TerminalIncubator` between
/// mounts so its libghostty surface is built up-front and stays alive —
/// otherwise PTY bytes that arrive while the panel isn't on screen would
/// be silently dropped. On mount we adopt the view into the panel; on
/// dismount we hand it back to the incubator.
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
            // The container can already hold a *different* emulator from a
            // prior workspace: park that one back in the incubator so its
            // surface stays alive instead of orphaning it.
            for sub in nsView.subviews where sub !== term {
                TerminalIncubator.park(sub)
            }
            attach(term, to: nsView)
        }
        context.coordinator.emulator = emulator as AnyObject
        emulator.setActive(true)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        // Hand the emulator back to the incubator so its surface keeps
        // receiving PTY output even though the panel is gone. The emulator
        // outlives this host — RunController/SetupController owns it.
        if let emulator = coordinator.emulator as? TerminalEmulatorView {
            MainActor.assumeIsolated {
                emulator.setActive(false)
                TerminalIncubator.park(emulator.nsView)
            }
        }
    }

    private func attach(_ term: NSView, to container: NSView) {
        TerminalIncubator.adopt(term, into: container)
        term.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            term.topAnchor.constraint(equalTo: container.topAnchor),
            term.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            term.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
    }
}
