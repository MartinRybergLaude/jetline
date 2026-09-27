#if os(macOS)
import SwiftUI
import QuickLook
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

    /// Ranks on the actor so a large worktree doesn't block typing.
    func ranked(in cwd: String, query: String) async -> [String] {
        Self.rank(await files(in: cwd), query: query)
    }

    /// Subsequence match, preferring hits in the file name and shorter paths.
    private static func rank(_ files: [String], query: String, limit: Int = 8) -> [String] {
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
    let session: ChatSession
    /// Completion popup state; ChatView draws the list above the timeline.
    let popup: ComposerPopup

    @State private var height: CGFloat = ComposerTextView.minHeight
    @State private var completion: ComposerCompletion?
    private var suggestions: [Suggestion] {
        get { popup.items }
        nonmutating set { popup.items = newValue }
    }
    private var highlighted: Int {
        get { popup.highlighted }
        nonmutating set { popup.highlighted = newValue }
    }
    @State private var replacement: ComposerTextView.Replacement?
    @State private var previewedImage: URL?

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
                    focusesOnAppear: true,
                    onCaretChange: updateCompletion,
                    onSubmit: submit,
                    onPopupKey: handlePopupKey,
                    onEscape: { if session.isWorking { session.interrupt() } },
                    onImages: { session.draftImages.append(contentsOf: $0) },
                    replacement: replacement
                )
                .frame(height: height)
                controls
                    // Optical alignment: pull the first pill's capsule out
                    // past the text column so its label, not its edge,
                    // lines up with the text above.
                    .padding(.leading, -8)
            }
        }
        .onAppear { popup.onAccept = { accept($0) } }
        .onDisappear {
            popup.items = []
            popup.onAccept = nil
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
        // One container so the capsules share a lensing pass and merge as
        // they touch, instead of refracting each other.
        GlassEffectContainer(spacing: 8) {
        HStack(alignment: .bottom, spacing: 8) {
            // Until the agent reports its models the pills can only show
            // placeholders; keep their space and fade them in once ready.
            // They wrap onto more rows when the column is narrow, so the
            // bar never forces the column wider than the pane.
            FlowLayout(spacing: 8) {
                ModelMenu(session: session)
                EffortMenu(session: session)
                RuntimeModeMenu(session: session)
                if session.supportsRemoteControl { RemoteControlMenu(session: session) }
            }
            .opacity(pillsReady ? 1 : 0)
            .allowsHitTesting(pillsReady)
            .animation(.easeOut(duration: 0.2), value: pillsReady)
            Spacer(minLength: 0)
            UsageMeter(usage: session.usage, limits: AgentRateLimits.shared.windows[session.provider] ?? [])
            if session.isWorking && session.draft.nonBlank == nil && session.draftImages.isEmpty {
                Button(action: session.interrupt) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: Self.roundButtonGlyph, height: Self.roundButtonGlyph)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Stop (Esc)")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: Self.roundButtonGlyph, height: Self.roundButtonGlyph)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .disabled(!canSend)
                .help("Send (Return)")
            }
        }
        }
    }

    /// Sized so the round buttons come out as tall as the pills.
    private static let roundButtonGlyph: CGFloat = 19

    /// The agent has reported in once. Its models outlive a disconnect
    /// (continuing in the terminal), so the pills stay up then.
    private var pillsReady: Bool {
        switch session.connection {
        case .connected, .failed: return true
        case .connecting, .disconnected: return !session.models.isEmpty
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
        FlowLayout(spacing: 8) {
            ForEach(session.draftImages, id: \.self) { url in
                AttachmentThumbnail(url: url, size: 72)
                    .onTapGesture { previewedImage = url }
                    .help("Quick Look")
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
        .quickLookPreview($previewedImage, in: session.draftImages)
    }

    // MARK: Completion

    private func updateCompletion(caret: Int) {
        let detected = ComposerCompletion.detect(in: session.draft, caret: caret)
        guard detected != completion else { return }
        completion = detected
        highlighted = 0
        popup.showsPaths = detected?.kind == .file
        guard let detected else {
            suggestions = []
            return
        }
        switch detected.kind {
        case .command:
            let q = detected.query.lowercased()
            suggestions = session.commands
                // Underscored commands are the CLI's internal plumbing.
                .filter { !$0.name.hasPrefix("_") && (q.isEmpty || $0.name.lowercased().contains(q)) }
                .sorted { ($0.name.lowercased().hasPrefix(q) ? 0 : 1, $0.name) < ($1.name.lowercased().hasPrefix(q) ? 0 : 1, $1.name) }
                .prefix(8)
                .map { Suggestion(insertion: "/" + $0.name, title: "/" + $0.name, detail: $0.description.nonBlank) }
        case .file:
            let cwd = session.cwd
            let query = detected.query
            Task {
                let ranked = await ChatFileIndex.shared.ranked(in: cwd, query: query)
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
    @EnvironmentObject private var state: AppState

    var body: some View {
        Menu {
            ForEach(AgentRuntimeMode.allCases, id: \.self) { mode in
                Button {
                    session.setRuntimeMode(mode)
                    state.rememberChatRuntimeMode(mode)
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

/// Remote Control: continue the chat from the Claude app or claude.ai.
private struct RemoteControlMenu: View {
    let session: ChatSession

    var body: some View {
        Menu {
            switch session.remoteControl {
            case .off:
                Button("Turn On Remote Control") { session.setRemoteControl(true) }
            case .starting:
                Text("Connecting…")
                Button("Cancel") { session.setRemoteControl(false) }
            case let .on(url):
                if let url {
                    Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Divider()
                }
                Button("Turn Off Remote Control") { session.setRemoteControl(false) }
            case let .failed(message):
                Text(message)
                Button("Try Again") { session.setRemoteControl(true) }
            }
        } label: {
            Label(label, systemImage: "iphone")
        }
        .pillMenu(tint: tint)
        .help("Continue this chat from the Claude app or claude.ai")
    }

    private var label: String {
        switch session.remoteControl {
        case .off, .failed: return "Remote"
        case .starting: return "Connecting…"
        case .on: return "Remote on"
        }
    }

    private var tint: PillTint? {
        switch session.remoteControl {
        case .on: return .accent
        case .failed: return .red
        case .off, .starting: return nil
        }
    }
}

enum PillTint {
    case red, yellow, accent

    var foreground: Color {
        switch self {
        case .red: return Color(nsColor: .pillRed)
        case .yellow: return Color(nsColor: .pillYellow)
        case .accent: return .accentColor
        }
    }

    var fill: Color {
        switch self {
        case .red: return Color.red.opacity(0.14)
        case .yellow: return Color.yellow.opacity(0.22)
        case .accent: return Color.accentColor.opacity(0.16)
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

/// Liquid Glass capsule with a trailing chevron; clear unless tinted.
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
        // Full access should read as a warning even in an inactive window.
        .glassCapsule(fill: tint?.fill)
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

/// Context fill as a ring; opens a popover with the numbers and the
/// plan's usage limits.
private struct UsageMeter: View {
    let usage: AgentTokenUsage?
    let limits: [AgentRateLimit]
    @State private var showing = false

    var body: some View {
        if usage != nil || !limits.isEmpty {
            Button { showing.toggle() } label: {
                Ring(fraction: contextFraction ?? 0, lineWidth: 2.5)
                    .frame(width: 18, height: 18)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Context and usage")
            .popover(isPresented: $showing, arrowEdge: .top) {
                UsagePopover(usage: usage, contextFraction: contextFraction, limits: limits)
            }
        }
    }

    private var contextFraction: Double? {
        guard let usage, let window = usage.contextWindow else { return nil }
        return min(1, Double(usage.contextTokens) / Double(max(window, 1)))
    }
}

private struct Ring: View {
    let fraction: Double
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(UsageTint.color(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private enum UsageTint {
    static func color(_ fraction: Double, normal: Color = .secondary) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : normal
    }
}

private struct UsagePopover: View {
    let usage: AgentTokenUsage?
    let contextFraction: Double?
    let limits: [AgentRateLimit]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let usage {
                UsageRow(
                    title: "Context",
                    fraction: contextFraction,
                    detail: contextDetail(usage)
                )
            }
            if usage != nil && !limits.isEmpty { Divider() }
            ForEach(limits) { limit in
                UsageRow(title: limit.name, fraction: limit.used, detail: resetText(limit.resetsAt))
            }
        }
        .padding(16)
        .frame(width: 260)
    }

    private func contextDetail(_ usage: AgentTokenUsage) -> String {
        let used = Self.tokens(usage.contextTokens)
        guard let window = usage.contextWindow else { return "\(used) tokens" }
        return "\(used) of \(Self.tokens(window)) tokens"
    }

    private func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Resets \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    private static func tokens(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

private struct UsageRow: View {
    let title: String
    let fraction: Double?
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                if let fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(UsageTint.color(fraction, normal: .accentColor))
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
