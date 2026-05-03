import SwiftUI

/// Settings tab for the inspector's git action bar. Top section picks the
/// agent that runs git tasks vs. the agent that runs reviews; bottom section
/// lets the user override the prompt template per action.
///
/// Empty prompt fields fall back to `GitActionPrompts.defaults`. The
/// placeholder shows the default verbatim so it's clear what blank means.
struct GitActionsSettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Agents") {
                AgentPicker(
                    title: "Git agent",
                    description: "Used for commit, create PR, pull updates, fix CI, and fix comments.",
                    binding: bindingAgent(\.gitAgent),
                    fallback: state.settings.defaultAgent
                )
                AgentPicker(
                    title: "Review agent",
                    description: "Used when you click Review.",
                    binding: bindingAgent(\.reviewAgent),
                    fallback: state.settings.defaultAgent
                )
            }

            Section("Prompts") {
                ForEach(GitAction.promptable, id: \.self) { action in
                    if let keyPath = action.settingsKeyPath {
                        PromptOverrideEditor(
                            action: action,
                            binding: bindingPrompt(for: keyPath)
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func bindingAgent(_ keyPath: WritableKeyPath<AppSettings, Workspace.AgentKind?>) -> Binding<Workspace.AgentKind?> {
        Binding(
            get: { state.settings[keyPath: keyPath] },
            set: { newValue in
                var s = state.settings
                s[keyPath: keyPath] = newValue
                state.saveSettings(s)
            }
        )
    }

    private func bindingPrompt(for keyPath: WritableKeyPath<AppSettings, String?>) -> Binding<String> {
        Binding(
            get: { state.settings[keyPath: keyPath] ?? "" },
            set: { newValue in
                var s = state.settings
                s[keyPath: keyPath] = newValue.nonBlank
                state.saveSettings(s)
            }
        )
    }
}

/// Picker that lets the user choose an agent or "Use default", which writes
/// `nil` to settings. Excludes `.shell` because it can't act on a prompt.
private struct AgentPicker: View {
    let title: String
    let description: String
    @Binding var binding: Workspace.AgentKind?
    let fallback: Workspace.AgentKind

    private var options: [Workspace.AgentKind] {
        Workspace.AgentKind.allCases.filter { $0 != .shell }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Picker("", selection: $binding) {
                    Text("Use default (\(fallback.displayName))").tag(Workspace.AgentKind?.none)
                    Divider()
                    ForEach(options, id: \.self) { kind in
                        Text(kind.displayName).tag(Workspace.AgentKind?.some(kind))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

/// Collapsible per-action prompt editor. Empty content inherits the built-in
/// default; the placeholder text shows that default so the user knows what
/// the empty state actually does.
struct PromptOverrideEditor: View {
    let action: GitAction
    @Binding var binding: String

    /// When `placeholder` is non-nil, that string overrides the built-in
    /// default — used by the per-repo editor to show the *resolved global*
    /// prompt instead of the hardcoded one.
    var placeholderOverride: String?

    @State private var expanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $binding)
                        .font(.system(.callout, design: .default))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                        .frame(minHeight: 80, maxHeight: 140)
                    if binding.isEmpty {
                        Text(placeholderText)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 13)
                            .allowsHitTesting(false)
                    }
                }
                HStack {
                    Text("Variables: {branch}, {baseBranch}, {prNumber}, {prTitle}, {prUrl}, {ciFailures}")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !binding.isEmpty {
                        Button("Reset to default") { binding = "" }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: action.systemImage)
                    .foregroundStyle(.secondary)
                Text(action.displayName)
                Spacer()
                if !binding.isEmpty {
                    Text("Custom")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
    }

    private var placeholderText: String {
        if let override = placeholderOverride, !override.isEmpty { return override }
        return GitActionPrompts.defaults[action] ?? ""
    }
}
