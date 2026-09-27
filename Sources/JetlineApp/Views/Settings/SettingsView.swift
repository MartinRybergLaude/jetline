#if os(macOS)
import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    /// Keyed off window activity, not appear/disappear — the Settings
    /// window can stay open behind the main window, and ⌘⇧ navigation
    /// should come back the moment the user clicks away from it.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
            GitActionsSettingsView()
                .tabItem { Label("Git Actions", systemImage: "arrow.triangle.branch") }
            EngineSettingsView()
                .tabItem { Label("Remote", systemImage: "network") }
        }
        .frame(width: 580, height: 520)
        .onChange(of: appearsActive, initial: true) { _, active in
            state.setNavShortcutsSuppressed(active, by: "app-settings")
        }
        .onDisappear { state.setNavShortcutsSuppressed(false, by: "app-settings") }
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Picker("Default agent", selection: state.settingsBinding(\.defaultAgent)) {
                ForEach(Workspace.AgentKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
    }
}

private struct AgentsSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Open Claude Code and Codex in", selection: state.settingsBinding(\.agentInterface)) {
                    Text("Terminal").tag(AppSettings.AgentInterface.terminal)
                    Text("Chat").tag(AppSettings.AgentInterface.chat)
                }
                Picker("New chats start in", selection: state.settingsBinding(\.chatRuntimeMode)) {
                    ForEach(AgentRuntimeMode.allCases, id: \.self) { mode in
                        Text("\(mode.displayName) — \(mode.summary)").tag(mode)
                    }
                }
                .disabled(state.settings.agentInterface != .chat)
            } footer: {
                Text("Chat drives the agent CLI directly and shows the conversation, tool calls, diffs and approvals in Jetline's own UI. The other interface stays available from the new-tab menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Claude Code") {
                Toggle("Show in new tab menu", isOn: bindingVisible(.claude))
                BinaryPathField(
                    title: "Binary path",
                    binding: bindingPath(\.claudeBinaryPath),
                    placeholder: "Auto-detected via PATH"
                )
            }
            Section("Codex") {
                Toggle("Show in new tab menu", isOn: bindingVisible(.codex))
                BinaryPathField(
                    title: "Binary path",
                    binding: bindingPath(\.codexBinaryPath),
                    placeholder: "Auto-detected via PATH"
                )
            }
            Section("Mistral Vibe") {
                Toggle("Show in new tab menu", isOn: bindingVisible(.vibe))
                BinaryPathField(
                    title: "Binary path",
                    binding: bindingPath(\.mistralBinaryPath),
                    placeholder: "Auto-detected via PATH"
                )
            }
            Section("Terminal") {
                Toggle("Show in new tab menu", isOn: bindingVisible(.shell))
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
    }

    private func bindingPath(_ keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { state.settings[keyPath: keyPath] ?? "" },
            set: { newValue in
                var s = state.settings
                s[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                state.saveSettings(s)
            }
        )
    }

    private func bindingVisible(_ agent: Workspace.AgentKind) -> Binding<Bool> {
        Binding(
            get: { state.settings.isAgentVisible(agent) },
            set: { newValue in
                var s = state.settings
                s.setAgent(agent, visible: newValue)
                state.saveSettings(s)
            }
        )
    }
}

private struct BinaryPathField: View {
    let title: String
    @Binding var binding: String
    let placeholder: String

    var body: some View {
        HStack {
            TextField(title, text: $binding, prompt: Text(placeholder))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    binding = url.path
                }
            }
        }
    }
}

private struct AppearanceSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: state.settingsBinding(\.theme)) {
                    Text("System").tag(AppSettings.Theme.system)
                    Text("Light").tag(AppSettings.Theme.light)
                    Text("Dark").tag(AppSettings.Theme.dark)
                }
            }
            Section {
                Picker("Assistant message font", selection: state.settingsBinding(\.chatFontFamily)) {
                    Text("System").tag(String?.none)
                    Divider()
                    ForEach(Self.fontFamilies, id: \.self) { family in
                        Text(family).tag(String?.some(family))
                    }
                }
                Picker("Monospace font", selection: state.settingsBinding(\.monospaceFontFamily)) {
                    Text("SF Mono").tag(String?.none)
                    Divider()
                    ForEach(MonoFont.installedFamilies, id: \.self) { family in
                        Text(family).tag(String?.some(family))
                    }
                }
            } footer: {
                Text("The monospace font is used by the terminal, diffs, code in chats and everywhere else text is monospaced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Terminal") {
                HStack {
                    Text("Font size")
                    Slider(value: state.settingsBinding(\.terminalFontSize), in: 9...20, step: 1)
                    Text("\(Int(state.settings.terminalFontSize))pt")
                        .frame(width: 36, alignment: .trailing)
                        .monoFont(.caption)
                }
                HStack {
                    Text("Horizontal padding")
                    Slider(value: bindingPaddingX, in: 0...40, step: 1)
                    Text("\(state.settings.terminalPaddingX)pt")
                        .frame(width: 36, alignment: .trailing)
                        .monoFont(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.visible)
    }

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    private var bindingPaddingX: Binding<Double> {
        Binding(
            get: { Double(state.settings.terminalPaddingX) },
            set: { newValue in
                var s = state.settings
                s.terminalPaddingX = Int(newValue.rounded())
                state.saveSettings(s)
            }
        )
    }
}

extension AppState {
    /// A binding that saves the settings on every write.
    func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { newValue in
                var s = self.settings
                s[keyPath: keyPath] = newValue
                self.saveSettings(s)
            }
        )
    }
}
#endif
