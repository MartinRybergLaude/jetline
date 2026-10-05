#if os(macOS)
import SwiftUI
import AppKit

/// Entry point for the `jetline` executable.
public func runJetlineApp() {
    JetlineApp.main()
}

struct JetlineApp: App {
    @NSApplicationDelegateAdaptor(JetlineAppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var updater = UpdaterViewModel()

    init() {
        // Resolve the user's login-shell PATH eagerly. Launchpad-launched
        // apps inherit launchd's minimal PATH, so without this every gh/git
        // spawn would miss homebrew until something paid the per-call
        // `command -v` cost. See `LoginShellPath`.
        LoginShellPath.prewarm()
    }

    var body: some Scene {
        // The main window isn't a scene: each of its tabs is a native window
        // tab, which SwiftUI has no API for — `MainWindowCoordinator` builds
        // it in AppKit. The app-wide menu commands hang off this scene.
        Window("Activity Log", id: "activity-log") {
            ActivityLogView()
                .environmentObject(state)
        }
        .defaultSize(width: 720, height: 500)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(vm: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Workspace…") {
                    state.openWorkspaceCreationForSelectedRepository()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(state.selectedRepository == nil)

                Divider()

                Button("New Tab") {
                    if let ws = activeWorkspace() {
                        state.startNewSession(for: ws, agent: state.settings.defaultAgent)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(state.selectedWorkspaceId == nil)

                Button("Close Tab") {
                    guard let wsId = state.selectedWorkspaceId else { return }
                    if let active = state.workspaceState(for: wsId).activeTab {
                        state.closeTab(active, in: wsId)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(state.selectedWorkspaceId == nil)

                Divider()

                Button("Add Repository…") {
                    Task {
                        if let repo = await state.addRepository() {
                            // Match the sidebar / welcome flow: drop the
                            // user straight into the new repo's settings
                            // sheet. Routed through AppState because the
                            // menu command has no view to host the sheet.
                            state.repoPendingSettings = repo
                        }
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Connect a Machine…") {
                    state.pendingRemoteSetup = RemoteSetupRequest(hostId: nil)
                }
            }
            CommandGroup(after: .windowArrangement) {
                Divider()

                Button("Next Tab") { state.cycleTab(forward: true) }
                    .keyboardShortcut("\t", modifiers: [.control])
                Button("Previous Tab") { state.cycleTab(forward: false) }
                    .keyboardShortcut("\t", modifiers: [.control, .shift])
                // The ⌘⇧ arrow/HJKL group disables itself while a settings
                // surface is being edited — disabled key equivalents fall
                // through to the field editor, restoring the standard
                // select-to-line-start/-end text behavior there.
                Group {
                    Button("Next Terminal Tab") { state.cycleTab(forward: true) }
                        .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                    Button("Previous Terminal Tab") { state.cycleTab(forward: false) }
                        .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])

                    Divider()

                    Button("Next Workspace") { state.cycleWorkspaceSelection(forward: true) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                    Button("Previous Workspace") { state.cycleWorkspaceSelection(forward: false) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .shift])

                    // Vim spellings of the four ⌘⇧ navigation arrows. Nested in a
                    // submenu so the Window menu doesn't list every action twice;
                    // key equivalents fire regardless of nesting.
                    Menu("Vim Navigation") {
                        Button("Previous Terminal Tab") { state.cycleTab(forward: false) }
                            .keyboardShortcut("h", modifiers: [.command, .shift])
                        Button("Next Workspace") { state.cycleWorkspaceSelection(forward: true) }
                            .keyboardShortcut("j", modifiers: [.command, .shift])
                        Button("Previous Workspace") { state.cycleWorkspaceSelection(forward: false) }
                            .keyboardShortcut("k", modifiers: [.command, .shift])
                        Button("Next Terminal Tab") { state.cycleTab(forward: true) }
                            .keyboardShortcut("l", modifiers: [.command, .shift])
                    }
                }
                .disabled(state.navShortcutsSuppressed)

                Divider()

                ForEach(1...9, id: \.self) { n in
                    Button("Show Tab \(n)") { state.selectTabByIndex(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Inspector") {
                    state.inspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
            // A `WindowGroup` brought these along; the AppKit-built main
            // window doesn't. The sidebar toggle goes up the responder chain
            // to the tab window's split controller.
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
                Button("Show All Tabs") {
                    NSApp.sendAction(#selector(NSWindow.toggleTabOverview(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                Button("Enter Full Screen") {
                    NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
            DebugCommands()
        }

        Window("Welcome to Jetline", id: "onboarding") {
            OnboardingView()
                .environmentObject(state)
                .preferredColorScheme(colorScheme(for: state.settings.theme))
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .commandsRemoved()

        Settings {
            SettingsView()
                .environmentObject(state)
                .preferredColorScheme(colorScheme(for: state.settings.theme))
        }
    }

    private func activeWorkspace() -> Workspace? {
        guard let id = state.selectedWorkspaceId else { return nil }
        return state.workspaceById(id)
    }

    private func colorScheme(for theme: AppSettings.Theme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Hidden Debug menu. Holds the entry point for the Activity Log window —
/// kept out of the user-facing flow, reachable via the menu bar or the
/// ⌘⌥⇧A shortcut.
private struct DebugCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Activity Log") {
                openWindow(id: "activity-log")
            }
            .keyboardShortcut("a", modifiers: [.command, .option, .shift])

            Button("Show Welcome") {
                openWindow(id: "onboarding")
            }
        }
    }
}

/// Builds the main window at launch, and intercepts ⌘Q / Quit-menu so the
/// user gets a chance to bail when there are live agent tabs. SwiftUI on
/// macOS otherwise tears the windows down without warning, killing every
/// running PTY mid-conversation.
@MainActor
final class JetlineAppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = MainWindowCoordinator(state: AppState.shared)
        mainWindow = coordinator
        coordinator.start()
    }

    /// Dock click: brings the main window back even when another window
    /// (Settings, a diagram) is still open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.showMainWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.saveFrame()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindow?.saveFrame()
        let state = AppState.shared
        guard let warning = state.quitWarning else { return stopAgentsThenTerminate(sender) }
        let alert = NSAlert()
        alert.messageText = "Quit Jetline?"
        alert.informativeText = warning
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return stopAgentsThenTerminate(sender)
    }

    /// Chat agents run in their own process sessions and wouldn't get the
    /// hangup terminal tabs do. Stop them before exiting, idle ones too.
    private func stopAgentsThenTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppState.shared.shutdownAgents()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
