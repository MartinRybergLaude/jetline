import SwiftUI
import AppKit

/// The PR's whole comment stream — description, issue comments, review
/// summaries and inline threads — in one scrollable timeline, with a
/// composer pinned to the bottom.
///
/// Owns its own layout (rather than being wrapped in `InspectorView`'s
/// shared `ScrollView`) so the filter bar and the composer stay put while
/// the timeline scrolls.
struct CommentsPanel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        if let id = state.inspectorWorkspaceId,
           let ws = state.workspaceById(id) {
            CommentsPanelContent(
                workspace: ws,
                workspaceState: state.workspaceState(for: ws.id)
            )
        } else {
            EmptyView()
        }
    }
}

private struct CommentsPanelContent: View {
    @EnvironmentObject private var state: AppState
    let workspace: Workspace
    let workspaceState: WorkspaceState
    @State private var hideResolved = false

    var body: some View {
        VStack(spacing: 0) {
            content(for: workspaceState.pr)
        }
        // Re-entered whenever the panel appears or the workspace changes, and
        // cancelled when either goes away — so the poll only runs while
        // someone is actually reading the tab. `refresh` collapses requests
        // that land inside its freshness window, so flipping tabs is free.
        .task(id: workspace.id) {
            while !Task.isCancelled {
                await state.conversationStore.refresh(workspaceId: workspace.id)
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    /// Gate on the PR snapshot first: with no PR there is nothing to fetch,
    /// and the placeholders should read the same as the PR tab's.
    @ViewBuilder
    private func content(for snapshot: PRSnapshot) -> some View {
        switch snapshot {
        case .loading:
            InspectorPlaceholder(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Loading PR…"
            )
        case let .error(message):
            InspectorPlaceholder(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't load PR",
                subtitle: message
            )
        case .absent:
            InspectorPlaceholder(
                systemImage: "tray",
                title: "No pull request",
                subtitle: "Branch \(workspace.branchName) has no PR on the remote."
            )
        case .loaded:
            conversationBody
        }
    }

    @ViewBuilder
    private var conversationBody: some View {
        switch workspaceState.conversation {
        case .idle, .loading:
            InspectorPlaceholder(
                systemImage: "arrow.triangle.2.circlepath",
                title: "Loading comments…"
            )
        case let .error(message):
            VStack(spacing: 0) {
                InspectorPlaceholder(
                    systemImage: "exclamationmark.triangle",
                    title: "Couldn't load comments",
                    subtitle: message
                )
                Button("Try again") {
                    Task { await state.conversationStore.refresh(workspaceId: workspace.id, force: true) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        case let .loaded(conversation):
            loaded(conversation)
        }
    }

    private func loaded(_ conversation: PRConversation) -> some View {
        VStack(spacing: 0) {
            CommentsToolbar(
                conversation: conversation,
                hideResolved: $hideResolved,
                workspaceId: workspace.id
            )
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let description = conversation.description {
                        CommentCard(comment: description, role: .description)
                    }
                    ForEach(visibleItems(conversation)) { item in
                        TimelineItemView(item: item, workspaceId: workspace.id)
                    }
                    if conversation.isEmpty {
                        InspectorPlaceholder(
                            systemImage: "bubble.left",
                            title: "No comments yet"
                        )
                    }
                    if conversation.truncated {
                        Text("Only the first 100 comments, reviews and threads are shown.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.visible)

            Divider()
            CommentComposer(workspaceId: workspace.id, number: conversation.number)
        }
        .textSelection(.enabled)
    }

    private func visibleItems(_ conversation: PRConversation) -> [PRTimelineItem] {
        hideResolved ? conversation.items.filter { !$0.isResolvedThread } : conversation.items
    }
}

// MARK: - Toolbar

private struct CommentsToolbar: View {
    @EnvironmentObject private var state: AppState
    let conversation: PRConversation
    @Binding var hideResolved: Bool
    let workspaceId: String
    @State private var isRefreshing = false

    var body: some View {
        HStack(spacing: 8) {
            if conversation.unresolvedCount > 0 {
                Label("\(conversation.unresolvedCount) unresolved", systemImage: "circle.dotted")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if conversation.resolvedCount > 0 {
                Label("All resolved", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 0)

            if conversation.resolvedCount > 0 {
                Toggle(isOn: $hideResolved) {
                    Text("Hide resolved (\(conversation.resolvedCount))")
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.caption)
            }

            Button {
                isRefreshing = true
                Task {
                    await state.conversationStore.refresh(workspaceId: workspaceId, force: true)
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("Refresh comments")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Timeline items

private struct TimelineItemView: View {
    let item: PRTimelineItem
    let workspaceId: String

    var body: some View {
        switch item {
        case let .comment(comment):
            CommentCard(comment: comment, role: .comment)
        case let .review(review):
            ReviewCard(review: review)
        case let .thread(thread):
            ReviewThreadCard(thread: thread, workspaceId: workspaceId)
        }
    }
}

/// Shared chrome for anything with an author, a timestamp and a markdown
/// body: the PR description, issue comments, and the comments inside a
/// review thread.
struct CommentCard: View {
    enum Role {
        case description, comment, threadComment

        var showsBorder: Bool { self != .threadComment }
    }

    let comment: PRComment
    var role: Role = .comment
    var style: MarkdownStyle = .comment
    @State private var revealMinimized = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CommentHeader(
                author: comment.author,
                date: comment.createdAt,
                trailing: role == .description ? "description" : nil,
                url: comment.url
            )

            if comment.isMinimized && !revealMinimized {
                Button {
                    revealMinimized = true
                } label: {
                    Text("Hidden\(comment.minimizedReason.map { " (\($0.lowercased()))" } ?? "") — show")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                MarkdownView(blocks: comment.blocks, style: style)
                    .opacity(comment.isMinimized ? 0.6 : 1)
            }
        }
        .padding(role.showsBorder ? 10 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if role.showsBorder {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
            }
        }
    }
}

private struct ReviewCard: View {
    let review: PRReview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(color)
                Text("\(review.author) \(review.verdict.label)")
                    .font(.caption.weight(.medium))
                Text(RelativeTime.string(for: review.submittedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                OpenOnGitHubButton(url: review.url)
            }
            if !review.blocks.isEmpty {
                MarkdownView(blocks: review.blocks)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.25), lineWidth: 0.5)
                )
        )
    }

    private var symbol: String {
        switch review.verdict {
        case .approved:         return "checkmark.circle.fill"
        case .changesRequested: return "xmark.circle.fill"
        case .commented:        return "text.bubble"
        case .dismissed:        return "minus.circle"
        }
    }

    /// Orange rather than yellow for "changes requested" text, matching the
    /// PR panel's review row — system yellow is unreadable on the light
    /// inspector background.
    private var color: Color {
        switch review.verdict {
        case .approved:         return .green
        case .changesRequested: return .red
        case .commented:        return .secondary
        case .dismissed:        return .secondary
        }
    }
}

// MARK: - Shared bits

struct CommentHeader: View {
    let author: String
    let date: Date
    var trailing: String?
    var url: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(author)
                .font(.caption.weight(.semibold))
            Text(RelativeTime.string(for: date))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 0)
            if let url { OpenOnGitHubButton(url: url) }
        }
    }
}

struct OpenOnGitHubButton: View {
    let url: String

    var body: some View {
        if let link = URL(string: url) {
            Button {
                NSWorkspace.shared.open(link)
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open on GitHub")
        }
    }
}

enum RelativeTime {
    /// `.distantPast` stands in for a timestamp GitHub didn't return (an
    /// unsubmitted review, a malformed date); rendering "56 years ago" for
    /// it would be worse than rendering nothing.
    static func string(for date: Date) -> String {
        guard date > Date(timeIntervalSince1970: 0) else { return "" }
        return date.formatted(.relative(presentation: .numeric))
    }
}

// MARK: - Composer

/// Top-level "comment on this PR" box, pinned below the timeline.
private struct CommentComposer: View {
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
                    .font(.caption2)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
            .font(.system(size: 12))
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
                        .font(.system(size: 12))
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
            .font(.caption)
        }
        .controlSize(.small)
        .disabled(isSubmitting || !isEnabled)
        .keyboardShortcut(shortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
    }
}
