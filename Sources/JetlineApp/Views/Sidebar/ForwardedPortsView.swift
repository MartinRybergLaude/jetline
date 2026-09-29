#if os(macOS)
import SwiftUI
import AppKit

/// A remote's forwarded ports, under its sidebar header: one line per port,
/// click to open it in the browser.
struct ForwardedPortsView: View {
    let ports: PortForwarder
    let onUpdateEngine: () -> Void

    var body: some View {
        let entries = ports.entries
        if !ports.isSupported {
            HStack(spacing: 6) {
                Text("This jetlined can't forward ports.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Update…", action: onUpdateEngine)
                    .buttonStyle(.link)
                    .font(.caption2)
            }
            .padding(.leading, ForwardedPortRow.iconInset + SidebarMetrics.iconColumn + SidebarMetrics.labelGap)
        } else if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(entries) { entry in
                    ForwardedPortRow(entry: entry, ports: ports)
                }
            }
        }
    }
}

private struct ForwardedPortRow: View {
    let entry: PortForwarder.Entry
    let ports: PortForwarder
    @State private var hovering = false

    private var url: URL { URL(string: "http://localhost:\(entry.port)")! }
    /// The header this sits in starts at the chevron column.
    static let iconInset = SidebarMetrics.iconLeading - SidebarMetrics.leading

    var body: some View {
        Button {
            if entry.state == .forwarding { NSWorkspace.shared.open(url) }
        } label: {
            // Drawn like a workspace row: glyph in the icon column, address
            // on the label edge, hover pill as wide as the rows' pills.
            HStack(spacing: SidebarMetrics.labelGap) {
                icon
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: SidebarMetrics.iconColumn)
                Text(verbatim: "localhost:\(entry.port)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(entry.state == .forwarding ? .primary : .secondary)
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                if hovering, entry.state == .forwarding {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Self.iconInset)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering && entry.state == .forwarding ? 0.06 : 0))
                    // Out to the row pills' edges, past the header's insets.
                    .padding(.leading, -SidebarMetrics.leading)
                    .padding(.trailing, -8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .contextMenu {
            Button("Open in Browser") { NSWorkspace.shared.open(url) }
                .disabled(entry.state != .forwarding)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Divider()
            if entry.state == .off {
                Button("Forward Port \(entry.port)") { ports.forward(entry.port) }
            } else {
                Button("Stop Forwarding") { ports.stopForwarding(entry.port) }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch entry.state {
        case .forwarding:
            Image(systemName: "arrow.left.arrow.right")
                .foregroundStyle(entry.isListening ? Color.green : Color.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .off:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
        }
    }

    private var note: String? {
        switch entry.state {
        case let .failed(message): return message
        case .off: return "off"
        case .forwarding:
            if !entry.isListening { return "not listening" }
            return entry.process
        }
    }

    private var help: String {
        switch entry.state {
        case .forwarding:
            let target = "port \(entry.port) on \(ports.hostName)"
            return entry.isListening
                ? "Forwarded from \(target). Click to open in the browser."
                : "Forwarded from \(target) — nothing is listening there right now."
        case let .failed(message):
            return "Can't forward port \(entry.port): \(message). Jetline keeps trying; free the port on this Mac to forward it."
        case .off:
            return "Port \(entry.port) is listening on \(ports.hostName) but not forwarded."
        }
    }
}

/// The port-forwarding items of a remote's header menu.
struct PortForwardingMenuItems: View {
    let ports: PortForwarder
    let onForwardPort: () -> Void

    var body: some View {
        let usable = ports.isSupported && !ports.isSameMachine
        Section("Ports") {
            Button(ports.forwardsAutomatically ? "✓ Forward Ports Automatically" : "Forward Ports Automatically") {
                ports.forwardsAutomatically.toggle()
            }
            .disabled(!usable)
            Button("Forward a Port…", action: onForwardPort)
                .disabled(!usable)
            ForEach(usable ? ports.otherPorts : []) { port in
                Button("Forward \(port.port)" + (port.process.map { " · \($0)" } ?? "")) {
                    ports.forward(port.port)
                }
            }
        }
    }
}
#endif
