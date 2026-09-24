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
                    Image(systemName: "clock").font(.system(size: 11))
                    Text(message.text).lineLimit(1)
                    Spacer()
                    Button {
                        session.removeQueued(message)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 13))
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
                        .font(.system(size: 13, design: completion?.kind == .file ? .monospaced : .default))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let detail = suggestion.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
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
                if model.efforts.count > 1 {
                    Menu {
                        ForEach(model.efforts, id: \.self) { effort in
                            Button {
                                select(model.id, effort: effort)
                            } label: {
                                if session.modelOption?.id == model.id, (session.effort ?? model.defaultEffort) == effort {
                                    Label(effort.capitalized, systemImage: "checkmark")
                                } else {
                                    Text(effort.capitalized)
                                }
                            }
                        }
                    } label: {
                        modelLabel(model)
                    } primaryAction: {
                        select(model.id, effort: nil)
                    }
                } else {
                    Button { select(model.id, effort: nil) } label: { modelLabel(model) }
                }
            }
        } label: {
            Text(title)
        }
        .pillMenu()
        .help(session.modelOption?.description ?? "Model")
    }

    private var title: String {
        let name = session.modelOption?.displayName ?? session.model ?? session.resolvedModel ?? "Default model"
        if let effort = session.effort { return "\(name) · \(effort)" }
        return name
    }

    @ViewBuilder
    private func modelLabel(_ model: AgentModelOption) -> some View {
        if session.modelOption?.id == model.id {
            Label(model.displayName, systemImage: "checkmark")
        } else {
            Text(model.displayName)
        }
    }

    private func select(_ model: String, effort: String?) {
        session.setModel(model, effort: effort)
        state.rememberChatModel(model, effort: effort, for: session.provider)
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
                        Label("\(mode.displayName) — \(mode.summary)", systemImage: "checkmark")
                    } else {
                        Text("\(mode.displayName) — \(mode.summary)")
                    }
                }
            }
        } label: {
            Label(session.runtimeMode.displayName, systemImage: session.runtimeMode.symbol)
        }
        .pillMenu()
        .help(session.runtimeMode.summary)
    }
}

private extension View {
    /// Capsule dropdown button for the composer's option menus.
    func pillMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .menuIndicator(.visible)
            .controlSize(.small)
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
                    .font(.system(size: 11, design: .monospaced))
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
