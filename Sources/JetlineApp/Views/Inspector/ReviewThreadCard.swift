import SwiftUI

/// One inline review thread: the diff it's anchored to, its comments, and
/// the reply / resolve actions.
///
/// Unresolved threads open expanded and resolved ones open collapsed to a
/// single line — the panel exists to work through what's still outstanding,
/// and a long-settled thread shouldn't cost a screen of scrolling.
struct ReviewThreadCard: View {
    let thread: PRReviewThread
    let workspaceId: String

    @EnvironmentObject private var state: AppState
    @State private var expanded: Bool
    @State private var isReplying = false
    @State private var replyText = ""
    @State private var isSubmitting = false
    @State private var isResolving = false
    @State private var errorMessage: String?
    @FocusState private var replyFocused: Bool

    init(thread: PRReviewThread, workspaceId: String) {
        self.thread = thread
        self.workspaceId = workspaceId
        // Only seeds the first render for this thread id. A thread the user
        // resolves from here therefore stays open, which is what you want
        // right after acting on it.
        _expanded = State(initialValue: !thread.isResolved)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded {
                if !thread.diffHunkLines.isEmpty {
                    ThreadDiffHunk(lines: thread.diffHunkLines)
                }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thread.comments) { comment in
                        CommentCard(comment: comment, role: .threadComment, style: .compact)
                    }
                }
                actions
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            } else {
                preview
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(
            fill: Color.secondary.opacity(thread.isResolved ? 0.04 : 0.07),
            stroke: borderColor
        )
        .opacity(thread.isOutdated && !expanded ? 0.75 : 1)
    }

    private var borderColor: Color {
        if thread.isResolved { return Color.secondary.opacity(0.15) }
        return Color.orange.opacity(0.35)
    }

    // MARK: Header

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(thread.location)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if thread.isOutdated { pill("OUTDATED", color: .secondary) }
                if thread.isResolved {
                    pill("RESOLVED", color: .readableGreen)
                } else {
                    Text("\(thread.comments.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(thread.path)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var preview: some View {
        HStack(spacing: 6) {
            Text(thread.comments.first?.author ?? "")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var snippet: String {
        let flattened = (thread.comments.first?.body ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flattened.count > 160 ? String(flattened.prefix(160)) + "…" : flattened
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        if isReplying {
            VStack(alignment: .leading, spacing: 6) {
                CommentEditor(text: $replyText, placeholder: "Reply…", focus: $replyFocused)
                    .frame(height: 54)
                HStack(spacing: 6) {
                    Button("Cancel") {
                        isReplying = false
                        replyText = ""
                        errorMessage = nil
                    }
                    .controlSize(.small)
                    .disabled(isSubmitting)
                    Spacer()
                    if canResolve {
                        SubmitButton(
                            title: "Reply & resolve",
                            isSubmitting: isSubmitting,
                            isEnabled: replyText.nonBlank != nil,
                            action: { submitReply(thenResolve: true) }
                        )
                    }
                    SubmitButton(
                        title: "Reply",
                        isSubmitting: isSubmitting,
                        isEnabled: replyText.nonBlank != nil,
                        shortcut: replyFocused,
                        action: { submitReply(thenResolve: false) }
                    )
                }
            }
        } else {
            HStack(spacing: 8) {
                if thread.viewerCanReply {
                    Button("Reply") {
                        isReplying = true
                        replyFocused = true
                    }
                    .controlSize(.small)
                }
                Spacer()
                resolveButton
            }
        }
    }

    private var canResolve: Bool { !thread.isResolved && thread.viewerCanResolve }

    @ViewBuilder
    private var resolveButton: some View {
        if thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
            SubmitButton(
                title: thread.isResolved ? "Unresolve" : "Resolve",
                isSubmitting: isResolving,
                isEnabled: !isSubmitting,
                action: { setResolved(!thread.isResolved) }
            )
        } else if let resolvedBy = thread.resolvedBy {
            Text("Resolved by \(resolvedBy)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func submitReply(thenResolve: Bool) {
        guard let body = replyText.nonBlank, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            var failure = await state.conversationStore.reply(
                workspaceId: workspaceId,
                threadId: thread.id,
                body: body,
                // The resolve's own refresh covers both mutations; refreshing
                // here too would spend a second `gh` round trip on a view of
                // the thread that's stale the moment the resolve lands.
                refreshAfter: !thenResolve
            )
            // The reply is the part that can't be redone by hand from here,
            // so a failed follow-up resolve must not look like a total
            // failure — report it, but keep the posted reply.
            if failure == nil, thenResolve {
                failure = await state.conversationStore.setResolved(
                    workspaceId: workspaceId,
                    threadId: thread.id,
                    resolved: true
                )
                if failure != nil {
                    failure = "Reply posted, but resolving failed: \(failure!)"
                }
            }
            isSubmitting = false
            if let failure {
                errorMessage = failure
            } else {
                replyText = ""
                isReplying = false
            }
        }
    }

    private func setResolved(_ resolved: Bool) {
        guard !isResolving else { return }
        isResolving = true
        errorMessage = nil
        Task {
            errorMessage = await state.conversationStore.setResolved(
                workspaceId: workspaceId,
                threadId: thread.id,
                resolved: resolved
            )
            isResolving = false
        }
    }
}

/// The unified-diff context GitHub attaches to a thread's first comment.
///
/// The commented line is the last one in the hunk, so the tail is what
/// matters; earlier context is available but folded away, because these
/// hunks routinely run 30+ lines and would bury the comments.
private struct ThreadDiffHunk: View {
    /// Pre-split by the decoder: this body re-evaluates on every keystroke in
    /// the enclosing card's reply editor.
    let lines: [String]
    @State private var showAll = false

    private static let tailLines = 8

    var body: some View {
        let hidden = max(0, lines.count - Self.tailLines)
        let shown = showAll ? lines : Array(lines.suffix(Self.tailLines))

        VStack(alignment: .leading, spacing: 0) {
            if hidden > 0 && !showAll {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAll = true }
                } label: {
                    Text("⌃ \(hidden) more line\(hidden == 1 ? "" : "s")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown.indices, id: \.self) { index in
                        line(shown[index])
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
        )
    }

    /// `nil` kind = the `@@ … @@` header, which reads as a caption rather
    /// than as diff content.
    private func line(_ text: String) -> some View {
        let kind = DiffLineTint.kind(ofRawLine: text)
        return Text(text.isEmpty ? " " : text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(kind == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.map(DiffLineTint.background) ?? DiffLineTint.headerBackground)
    }
}
