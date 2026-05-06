import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AgentsSettingsView()
                .tabItem { Label("Agents", systemImage: "sparkles") }
            GitActionsSettingsView()
                .tabItem { Label("Git Actions", systemImage: "arrow.triangle.branch") }
            TerminalSettingsView()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 580, height: 520)
    }
}

private struct GeneralSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Picker("Default agent", selection: bindingDefaultAgent) {
                ForEach(Workspace.AgentKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Picker("Theme", selection: bindingTheme) {
                Text("System").tag(AppSettings.Theme.system)
                Text("Light").tag(AppSettings.Theme.light)
                Text("Dark").tag(AppSettings.Theme.dark)
            }
        }
        .formStyle(.grouped)
    }

    private var bindingDefaultAgent: Binding<Workspace.AgentKind> {
        Binding(
            get: { state.settings.defaultAgent },
            set: { newValue in
                var s = state.settings
                s.defaultAgent = newValue
                state.saveSettings(s)
            }
        )
    }

    private var bindingTheme: Binding<AppSettings.Theme> {
        Binding(
            get: { state.settings.theme },
            set: { newValue in
                var s = state.settings
                s.theme = newValue
                state.saveSettings(s)
            }
        )
    }
}

private struct AgentsSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
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

private struct TerminalSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            TextField("Font family",
                      text: bindingFont)
            HStack {
                Text("Font size")
                Slider(value: bindingFontSize, in: 9...20, step: 1)
                Text("\(Int(state.settings.terminalFontSize))pt")
                    .frame(width: 36, alignment: .trailing)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .formStyle(.grouped)
    }

    private var bindingFont: Binding<String> {
        Binding(
            get: { state.settings.terminalFontFamily },
            set: { newValue in
                var s = state.settings
                s.terminalFontFamily = newValue
                state.saveSettings(s)
            }
        )
    }

    private var bindingFontSize: Binding<Double> {
        Binding(
            get: { state.settings.terminalFontSize },
            set: { newValue in
                var s = state.settings
                s.terminalFontSize = newValue
                state.saveSettings(s)
            }
        )
    }
}
