import SwiftUI
import AppKit

/// A `/command` or `@file` token being typed at the caret.
struct ComposerCompletion: Equatable {
    enum Kind { case command, file }

    var kind: Kind
    /// UTF-16 range of the token, trigger character included.
    var range: NSRange
    var query: String

    /// Slash commands only complete at the very start of the message (that's
    /// the only place the CLIs treat them as commands); mentions anywhere.
    static func detect(in text: String, caret: Int) -> ComposerCompletion? {
        let ns = text as NSString
        guard caret <= ns.length else { return nil }
        var start = caret
        while start > 0 {
            let char = ns.character(at: start - 1)
            if let scalar = Unicode.Scalar(char), CharacterSet.whitespacesAndNewlines.contains(scalar) { break }
            start -= 1
        }
        guard start < caret else { return nil }
        let token = ns.substring(with: NSRange(location: start, length: caret - start))
        if token.hasPrefix("/"), start == 0 {
            return ComposerCompletion(kind: .command, range: NSRange(location: start, length: caret - start), query: String(token.dropFirst()))
        }
        if token.hasPrefix("@") {
            return ComposerCompletion(kind: .file, range: NSRange(location: start, length: caret - start), query: String(token.dropFirst()))
        }
        return nil
    }

    /// `text` with the token replaced by `insertion` and a trailing space,
    /// plus the caret offset after it.
    func apply(_ insertion: String, to text: String) -> (text: String, caret: Int) {
        let replacement = insertion + " "
        let result = (text as NSString).replacingCharacters(in: range, with: replacement)
        return (result, range.location + (replacement as NSString).length)
    }
}

/// Tracked files of a worktree, for `@` mentions. Refreshed at most every
/// 30 seconds per directory.
actor ChatFileIndex {
    static let shared = ChatFileIndex()
    private var cache: [String: (files: [String], at: Date)] = [:]

    func files(in cwd: String) async -> [String] {
        if let cached = cache[cwd], Date().timeIntervalSince(cached.at) < 30 { return cached.files }
        let out = (try? await GitRunner.runChecked(["ls-files", "-co", "--exclude-standard"], cwd: cwd)) ?? ""
        let files = Array(out.split(separator: "\n").prefix(50_000).map(String.init))
        cache[cwd] = (files, Date())
        return files
    }

    /// Subsequence match, preferring hits in the file name and shorter paths.
    static func rank(_ files: [String], query: String, limit: Int = 8) -> [String] {
        guard !query.isEmpty else { return Array(files.prefix(limit)) }
        let q = query.lowercased()
        var scored: [(String, Int)] = []
        for path in files {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            var score: Int
            if name.hasPrefix(q) { score = 1000 }
            else if name.contains(q) { score = 800 }
            else if lower.contains(q) { score = 500 }
            else if isSubsequence(q, of: lower) { score = 100 }
            else { continue }
            score -= path.count
            scored.append((path, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = haystack.startIndex
        for c in needle {
            guard let found = haystack[index...].firstIndex(of: c) else { return false }
            index = haystack.index(after: found)
        }
        return true
    }
}

struct ChatComposer: View {
    @EnvironmentObject private var state: AppState
    let session: ChatSession

    @State private var height: CGFloat = ComposerTextView.minHeight
    @State private var completion: ComposerCompletion?
    @State private var suggestions: [Suggestion] = []
    @State private var highlighted = 0
    @State private var replacement: ComposerTextView.Replacement?

    struct Suggestion: Identifiable, Equatable {
        var id: String { insertion }
        var insertion: String
        var title: String
        var detail: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.queued.isEmpty { queuedRow }
            if !session.draftImages.isEmpty { attachmentsRow }
            VStack(alignment: .leading, spacing: 8) {
                ComposerTextView(
                    text: Binding(get: { session.draft }, set: { session.draft = $0 }),
                    height: $height,
                    placeholder: placeholder,
                    isFocused: true,
                    onCaretChange: updateCompletion,
                    onSubmit: submit,
                    onPopupKey: handlePopupKey,
                    onEscape: { if session.isWorking { session.interrupt() } },
                    onImages: { session.draftImages.append(contentsOf: $0) },
                    replacement: replacement
                )
                .frame(height: height)
                controls
            }
            .overlay(alignment: .topLeading) {
                if !suggestions.isEmpty {
                    suggestionList
                        .alignmentGuide(.top) { $0[.bottom] + 6 }
                }
            }
        }
    }

    private var placeholder: String {
        if session.isWorking {
            return session.provider == .codex ? "Steer the agent…" : "Queue a follow-up…"
        }
        return "Ask \(session.provider.displayName)…"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 8) {
            ModelMenu(session: session)
            EffortMenu(session: session)
            RuntimeModeMenu(session: session)
            Spacer()
            if let usage = session.usage { ContextMeter(usage: usage) }
            if session.isWorking && session.draft.nonBlank == nil && session.draftImages.isEmpty {
                Button(action: session.interrupt) {
                    Image(systemName: "stop.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("Stop (Esc)")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
    }

    private var canSend: Bool {
        session.draft.nonBlank != nil || !session.draftImages.isEmpty
    }

    private var queuedRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.queued) { message in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 12))
                    Text(message.text).lineLimit(1)
                    Spacer()
                    Button {
                        session.removeQueued(message)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .help("Sent when the current turn finishes")
            }
        }
    }

    private var attachmentsRow: some View {
        HStack(spacing: 8) {
            ForEach(session.draftImages, id: \.self) { url in
                AttachmentThumbnail(url: url, size: 52)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            session.draftImages.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                    }
            }
        }
    }

    // MARK: Completion

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                HStack(spacing: 8) {
                    Text(suggestion.title)
                        .font(.system(size: 14, design: completion?.kind == .file ? .monospaced : .default))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let detail = suggestion.detail {
                        Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(index == highlighted ? Color.accentColor.opacity(0.18) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { accept(suggestion) }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func updateCompletion(caret: Int) {
        let detected = ComposerCompletion.detect(in: session.draft, caret: caret)
        guard detected != completion else { return }
        completion = detected
        highlighted = 0
        guard let detected else {
            suggestions = []
            return
        }
        switch detected.kind {
        case .command:
            let q = detected.query.lowercased()
            suggestions = session.commands
                .filter { q.isEmpty || $0.name.lowercased().contains(q) }
                .sorted { ($0.name.lowercased().hasPrefix(q) ? 0 : 1, $0.name) < ($1.name.lowercased().hasPrefix(q) ? 0 : 1, $1.name) }
                .prefix(8)
                .map { Suggestion(insertion: "/" + $0.name, title: "/" + $0.name, detail: $0.description.nonBlank) }
        case .file:
            let cwd = session.cwd
            let query = detected.query
            Task {
                let files = await ChatFileIndex.shared.files(in: cwd)
                let ranked = ChatFileIndex.rank(files, query: query)
                guard completion == detected else { return }
                suggestions = ranked.map { Suggestion(insertion: "@" + $0, title: $0, detail: nil) }
            }
        }
    }

    private func handlePopupKey(_ key: ComposerKey) -> Bool {
        guard !suggestions.isEmpty else { return false }
        switch key {
        case .up: highlighted = (highlighted - 1 + suggestions.count) % suggestions.count
        case .down: highlighted = (highlighted + 1) % suggestions.count
        case .accept: accept(suggestions[min(highlighted, suggestions.count - 1)])
        case .dismiss:
            suggestions = []
            completion = nil
        }
        return true
    }

    private func accept(_ suggestion: Suggestion) {
        guard let completion else { return }
        let (text, caret) = completion.apply(suggestion.insertion, to: session.draft)
        replacement = .init(text: text, caret: caret)
        session.draft = text
        suggestions = []
        self.completion = nil
    }

    private func submit() {
        guard canSend else { return }
        session.send(text: session.draft, images: session.draftImages)
        session.draft = ""
        session.draftImages = []
        replacement = .init(text: "", caret: 0)
        suggestions = []
        completion = nil
    }
}

private struct ModelMenu: View {
    @EnvironmentObject private var state: AppState
    let session: ChatSession

    var body: some View {
        Menu {
            if session.models.isEmpty {
                Text(session.connection == .connected ? "No models reported" : "Connecting…")
            }
            ForEach(session.models) { model in
                Button { select(model) } label: {
                    if session.modelOption?.id == model.id {
                        Label(model.displayName, systemImage: "checkmark")
                    } else {
                        Text(model.displayName)
                    }
                }
            }
        } label: {
            Text(session.modelOption?.displayName ?? session.model ?? session.resolvedModel ?? "Default model")
        }
        .pillMenu()
        .help(session.modelOption?.description ?? "Model")
    }

    /// Keeps the chosen effort when the new model supports it.
    private func select(_ model: AgentModelOption) {
        let effort = session.effort.flatMap { model.efforts.contains($0) ? $0 : nil }
        session.setModel(model.id, effort: effort)
        state.rememberChatModel(model.id, effort: effort, for: session.provider)
    }
}

/// Reasoning effort for the current model; hidden when it has no choice.
private struct EffortMenu: View {
    @EnvironmentObject private var state: AppState
    let session: ChatSession

    var body: some View {
        if let model = session.modelOption, model.efforts.count > 1 {
            Menu {
                Button { select(nil, model: model) } label: {
                    let title = model.defaultEffort.map { "Default (\($0.capitalized))" } ?? "Default"
                    if session.effort == nil {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
                Divider()
                ForEach(model.efforts, id: \.self) { effort in
                    Button { select(effort, model: model) } label: {
                        if session.effort == effort {
                            Label(effort.capitalized, systemImage: "checkmark")
                        } else {
                            Text(effort.capitalized)
                        }
                    }
                }
            } label: {
                Label((session.effort ?? model.defaultEffort)?.capitalized ?? "Default effort", systemImage: "gauge.with.dots.needle.50percent")
            }
            .pillMenu(tint: tint(for: session.effort ?? model.defaultEffort))
            .help("Reasoning effort")
        }
    }

    /// Flags the slow, token-hungry levels.
    private func tint(for effort: String?) -> PillTint? {
        switch effort?.lowercased() {
        case "max": return .red
        case "xhigh": return .yellow
        default: return nil
        }
    }

    private func select(_ effort: String?, model: AgentModelOption) {
        session.setModel(model.id, effort: effort)
        state.rememberChatModel(model.id, effort: effort, for: session.provider)
    }
}

private struct RuntimeModeMenu: View {
    let session: ChatSession

    var body: some View {
        Menu {
            ForEach(AgentRuntimeMode.allCases, id: \.self) { mode in
                Button {
                    session.setRuntimeMode(mode)
                } label: {
                    if mode == session.runtimeMode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            Label(session.runtimeMode.displayName, systemImage: session.runtimeMode.symbol)
        }
        .pillMenu(tint: tint)
        .help(session.runtimeMode.summary)
    }

    /// Warns when the agent runs without asking.
    private var tint: PillTint? {
        switch session.runtimeMode {
        case .fullAccess: return .red
        case .auto: return .yellow
        case .supervised, .acceptEdits: return nil
        }
    }
}

enum PillTint {
    case red, yellow

    var foreground: Color {
        switch self {
        case .red: return Color(nsColor: .pillRed)
        case .yellow: return Color(nsColor: .pillYellow)
        }
    }

    var fill: Color {
        switch self {
        case .red: return Color.red.opacity(0.14)
        case .yellow: return Color.yellow.opacity(0.22)
        }
    }
}

private extension NSColor {
    static let pillRed = NSColor(name: "pillRed") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.5, blue: 0.47, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.1, blue: 0.1, alpha: 1)
    }
    static let pillYellow = NSColor(name: "pillYellow") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.82, blue: 0.35, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.38, blue: 0, alpha: 1)
    }
}

/// Capsule with a trailing chevron; gray unless tinted.
private struct PillButtonStyle: ButtonStyle {
    var tint: PillTint?

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.label
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .opacity(0.7)
        }
        .font(.system(size: 13))
        .foregroundStyle(tint?.foreground ?? Color.primary)
        // Fixed height: symbols differ in height (the Full access bolt is
        // taller), which would otherwise resize the pill per mode.
        .imageScale(.small)
        .frame(height: 28)
        .padding(.horizontal, 12)
        .background(Capsule().fill(tint?.fill ?? Color.secondary.opacity(0.12)))
        .opacity(configuration.isPressed ? 0.7 : 1)
        .contentShape(Capsule())
    }
}

private extension View {
    /// Capsule dropdown button for the composer's option menus.
    func pillMenu(tint: PillTint? = nil) -> some View {
        menuStyle(.button)
            .buttonStyle(PillButtonStyle(tint: tint))
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

private struct ContextMeter: View {
    let usage: AgentTokenUsage

    var body: some View {
        let fraction = usage.contextWindow.map { min(1, Double(usage.contextTokens) / Double(max($0, 1))) }
        HStack(spacing: 4) {
            if let fraction {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(fraction > 0.85 ? Color.orange : Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 11, height: 11)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        let used = Self.format(usage.contextTokens)
        guard let window = usage.contextWindow else { return "\(used) tokens in context" }
        return "\(used) of \(Self.format(window)) tokens in context"
    }

    private static func format(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}
