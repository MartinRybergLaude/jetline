import SwiftUI

/// Top-level so `AppState` can drive selection from outside the view (e.g.
/// switch to `.run` when a fresh workspace's setup script kicks off).
enum InspectorTab: Hashable { case changes, pr, run }

struct InspectorView: View {
    @EnvironmentObject private var state: AppState
    @State private var diffMode: DiffMode = .combined

    var body: some View {
        VStack(spacing: 0) {
            CapsuleTabs(
                selection: $state.inspectorTab,
                tabs: [.changes, .pr, .run],
                help: { Self.tooltip(for: $0) }
            ) { tab, _ in
                Self.icon(for: tab)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) { Divider() }

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
        switch state.inspectorTab {
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

    private static func tooltip(for tab: InspectorTab) -> String? {
        switch tab {
        case .changes: return "Changes"
        case .pr: return "Pull request"
        case .run: return "Run output"
        }
    }

    @ViewBuilder
    private static func icon(for tab: InspectorTab) -> some View {
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
            if let url = Bundle.jetlineResources.url(forResource: name, withExtension: "png"),
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
            set: { mode = $0 ? .local : .combined }
        )
    }

    var body: some View {
        Toggle(isOn: isLocal) {
            Text("Only uncommitted")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .help(mode == .local
              ? "Showing uncommitted (staged + unstaged) changes"
              : "Showing all changes vs base branch (committed + uncommitted)")
    }
}
