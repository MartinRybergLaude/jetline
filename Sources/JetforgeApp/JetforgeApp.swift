import SwiftUI
import AppKit

@main
struct JetforgeApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(state)
                .preferredColorScheme(colorScheme(for: state.settings.theme))
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tab") {
                    if let ws = activeWorkspace() {
                        state.startNewSession(for: ws, agent: state.settings.defaultAgent)
                    }
                }
                .keyboardShortcut("t", modifiers: [.command])
                .disabled(state.selectedWorkspaceId == nil)

                Button("Close Tab") {
                    if let wsId = state.selectedWorkspaceId,
                       let active = state.activeSessionByWorkspace[wsId] {
                        state.closeSession(active, in: wsId)
                    }
                }
                .keyboardShortcut("w", modifiers: [.command])
                .disabled(state.selectedWorkspaceId == nil)

                Divider()

                Button("Add Repository…") {
                    Task { await state.addRepository() }
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(after: .windowArrangement) {
                Divider()

                Button("Next Tab") { state.cycleSession(forward: true) }
                    .keyboardShortcut("\t", modifiers: [.control])
                Button("Previous Tab") { state.cycleSession(forward: false) }
                    .keyboardShortcut("\t", modifiers: [.control, .shift])

                Divider()

                ForEach(1...9, id: \.self) { n in
                    Button("Show Tab \(n)") { state.selectSessionByIndex(n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [.command])
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Toggle Inspector") {
                    state.inspectorVisible.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
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
