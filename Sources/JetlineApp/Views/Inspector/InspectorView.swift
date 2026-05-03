import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @State private var tab: Tab = .changes
    @State private var diffMode: DiffMode = .pr

    enum Tab: Hashable { case changes, pr, run }

    var body: some View {
        VStack(spacing: 0) {
            CapsuleTabs(
                selection: $tab,
                tabs: [.changes, .pr, .run],
                help: { Self.tooltip(for: $0) }
            ) { tab, _ in
                Self.icon(for: tab)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Run output owns its own ScrollView (autoscroll-to-tail), so it sits
    /// directly in the layout; the diff/PR panels are static content and get
    /// wrapped in a scroll view here.
    @ViewBuilder
    private var content: some View {
        switch tab {
        case .changes:
            VStack(spacing: 0) {
                DiffModeToggle(mode: $diffMode)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                ScrollView { ChangesPanel(mode: diffMode).padding(.vertical, 8) }
            }
        case .pr:
            ScrollView { PRPanel().padding(.vertical, 8) }
        case .run:
            RunOutputPanel()
        }
    }

    private static func tooltip(for tab: Tab) -> String? {
        switch tab {
        case .changes: return "Changes"
        case .pr: return "Pull request"
        case .run: return "Run output"
        }
    }

    @ViewBuilder
    private static func icon(for tab: Tab) -> some View {
        switch tab {
        case .changes:
            Image(systemName: "plusminus")
        case .pr:
            if let nsImage = assetCache["PRStateNone"] {
                Image(nsImage: nsImage).resizable().scaledToFit().frame(width: 13, height: 13)
            }
        case .run:
            Image(systemName: "apple.terminal.fill")
        }
    }

    private static let assetCache: [String: NSImage] = {
        let names = ["PRStateNone"]
        var map: [String: NSImage] = [:]
        for name in names {
            if let url = Bundle.module.url(forResource: name, withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                map[name] = img
            }
        }
        return map
    }()
}

private struct DiffModeToggle: View {
    @Binding var mode: DiffMode

    private var isLocal: Binding<Bool> {
        Binding(
            get: { mode == .local },
            set: { mode = $0 ? .local : .pr }
        )
    }

    var body: some View {
        Toggle(isOn: isLocal) {
            Text("Only uncommitted")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(mode == .pr
              ? "Showing committed changes vs base branch"
              : "Showing uncommitted (staged + unstaged) changes")
    }
}
