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
                Button("Add Repository…") {
                    Task { await state.addRepository() }
                }
                .keyboardShortcut("o", modifiers: [.command])
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

    private func colorScheme(for theme: AppSettings.Theme) -> ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
