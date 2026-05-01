import SwiftUI

/// Read-only viewer for the Run script's stdout/stderr stream.
struct RunOutputSheet: View {
    @ObservedObject var controller: RunController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: controller.isRunning ? "circle.fill" : "circle")
                    .foregroundStyle(controller.isRunning ? .green : .secondary)
                    .font(.caption)
                Text(controller.isRunning
                     ? "Running"
                     : exitDescription)
                    .font(.headline)
                Spacer()
                if controller.isRunning {
                    Button("Stop") { controller.stop() }
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.output.isEmpty ? "(no output yet)" : controller.output)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
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
        .frame(width: 720, height: 480)
    }

    private var exitDescription: String {
        if let s = controller.exitStatus { return "Exited (\(s))" }
        return "Idle"
    }
}
