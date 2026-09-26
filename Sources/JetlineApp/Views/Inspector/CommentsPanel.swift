import SwiftUI

/// The conversation's header row: title, resolution count, the hide
/// resolved toggle, and the loading / error states before a conversation
/// arrives. The cards themselves are AppKit (see `PRTimelineNodes`).
struct PRConversationHeader: View {
    @EnvironmentObject private var state: AppState
    let workspaceId: String
    let workspaceState: WorkspaceState
    @Environment(InspectorUIState.self) private var ui

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(workspaceState.conversation.conversation)
            switch workspaceState.conversation {
            case .idle, .loading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading comments…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case let .error(message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Couldn't load comments", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await state.conversationStore.refresh(workspaceId: workspaceId, force: true) }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            case .loaded:
                EmptyView()
            }
        }
    }

    /// Laid out like the Review and Checks headers above it, so the panel
    /// reads as one column of sections.
    private func header(_ conversation: PRConversation?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Conversation")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let conversation {
                    if conversation.unresolvedCount > 0 {
                        Label("\(conversation.unresolvedCount) unresolved", systemImage: "circle.dotted")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else if conversation.resolvedCount > 0 {
                        Label("All resolved", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(Color.readableGreen)
                    }
                }
            }
            if let conversation, conversation.resolvedCount > 0 {
                Toggle(isOn: Bindable(ui).hideResolvedComments) {
                    Text("Hide resolved (\(conversation.resolvedCount))")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.callout)
            }
        }
        .padding(.top, 4)
    }
}

@MainActor
enum RelativeTime {
    /// Memoized per (timestamp, current minute): the formatter is ICU-backed
    /// and costs ~5µs a call, and every visible comment header re-renders it
    /// on each pass over the timeline for a value that changes once a minute.
    private static var cache: [Date: String] = [:]
    private static var cachedMinute: Int = .min

    /// `.distantPast` stands in for a timestamp GitHub didn't return (an
    /// unsubmitted review, a malformed date); rendering "56 years ago" for
    /// it would be worse than rendering nothing.
    static func string(for date: Date) -> String {
        guard date > Date(timeIntervalSince1970: 0) else { return "" }

        let minute = Int(Date().timeIntervalSinceReferenceDate / 60)
        if minute != cachedMinute {
            cachedMinute = minute
            cache.removeAll(keepingCapacity: true)
        }
        if let hit = cache[date] { return hit }

        let formatted = date.formatted(.relative(presentation: .numeric))
        cache[date] = formatted
        return formatted
    }
}

// MARK: - Composer

/// Top-level "comment on this PR" box, at the end of the timeline.
struct CommentComposer: View {
    @EnvironmentObject private var state: AppState
    let workspaceId: String
    let number: Int
    @State private var text = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            CommentEditor(text: $text, placeholder: "Comment on #\(number)…", focus: $focused)
                .frame(height: 58)
            HStack {
                Spacer()
                SubmitButton(
                    title: "Comment",
                    isSubmitting: isSubmitting,
                    isEnabled: text.nonBlank != nil,
                    shortcut: focused,
                    action: submit
                )
            }
        }
    }

    private func submit() {
        guard let body = text.nonBlank, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            let failure = await state.conversationStore.postComment(
                workspaceId: workspaceId,
                body: body
            )
            isSubmitting = false
            if let failure {
                errorMessage = failure
            } else {
                text = ""
            }
        }
    }
}

/// `TextEditor` with a placeholder and chrome that matches the inspector.
/// `scrollContentBackground(.hidden)` is required — otherwise the editor
/// paints its own opaque `textBackgroundColor` over the rounded border.
struct CommentEditor: View {
    @Binding var text: String
    let placeholder: String
    /// Bound to the caller's `@FocusState` so the submit button can claim
    /// ⌘↩ only while this editor holds focus — several composers can be on
    /// screen at once, and duplicate key equivalents resolve arbitrarily.
    var focus: FocusState<Bool>.Binding

    var body: some View {
        TextEditor(text: $text)
            .focused(focus)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
            )
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }
}

struct SubmitButton: View {
    let title: String
    let isSubmitting: Bool
    let isEnabled: Bool
    /// Claims ⌘↩. Only ever true for the one composer that currently has
    /// focus; see `CommentEditor.focus`.
    var shortcut: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                }
                Text(title)
            }
            .font(.callout)
        }
        .controlSize(.small)
        .disabled(isSubmitting || !isEnabled)
        .keyboardShortcut(shortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
    }
}
