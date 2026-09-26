import SwiftUI

/// Takes the composer's place while the agent waits on the user. One
/// request at a time, oldest first.
struct ChatRequestPanel: View {
    let session: ChatSession
    let request: AgentRequest

    var body: some View {
        Group {
            switch request.kind {
            case let .approval(approval):
                ApprovalPanel(
                    approval: approval,
                    item: session.item(for: request),
                    cwd: session.cwd,
                    pendingCount: session.requests.count
                ) { decision in
                    session.respond(to: request, with: decision)
                }
            case let .questions(questions):
                QuestionsPanel(questions: questions) { answers in
                    session.answer(request, answers: answers)
                }
            case .plan:
                PlanApprovalPanel(defaultMode: session.runtimeMode == .supervised ? .acceptEdits : session.runtimeMode) { decision in
                    session.resolvePlan(request, with: decision)
                }
            }
        }
        .id(request.id)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.45), lineWidth: 1))
    }
}

private struct ApprovalPanel: View {
    let approval: AgentApproval
    /// The tool call being approved, when the provider links it.
    let item: AgentItem?
    let cwd: String
    let pendingCount: Int
    let decide: (AgentApprovalDecision) -> Void
    @State private var denyMessage = ""
    @State private var explaining = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(.orange)
                Text(approval.title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if pendingCount > 1 {
                    Text("\(pendingCount) waiting").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let diff = proposedDiff {
                ScrollView {
                    InlineDiffView(diff: diff)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = displayDetail {
                ScrollView {
                    Text(detail)
                        .monoFont(size: 14)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if let reason = approval.reason, !reason.isEmpty, reason != approval.detail {
                Text(reason).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            if explaining {
                TextField("Tell the agent what to do instead (optional)", text: $denyMessage)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { decide(.deny(message: denyMessage.nonBlank)) }
            }
            HStack(spacing: 8) {
                Button("Stop turn", role: .destructive) { decide(.cancel) }
                    .help("Decline and stop the agent's turn")
                Spacer()
                if explaining {
                    Button("Decline") { decide(.deny(message: denyMessage.nonBlank)) }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Decline…") {
                        explaining = true
                        focused = true
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if approval.allowsSessionScope {
                    Button(sessionLabel) { decide(.allowForSession) }
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                }
                Button("Allow") { decide(.allowOnce) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
    }

    /// For file edits, the change itself says more than the path.
    private var proposedDiff: String? {
        guard case let .fileChange(change)? = item?.content else { return nil }
        let diffs = change.edits.compactMap { edit -> String? in
            guard let diff = edit.diff, !diff.isEmpty else { return nil }
            return change.edits.count > 1 ? "\(edit.path.relative(to: cwd))\n\(diff)" : diff
        }
        return diffs.isEmpty ? nil : diffs.joined(separator: "\n")
    }

    private var displayDetail: String? {
        guard let detail = approval.detail?.nonBlank else { return nil }
        return detail.split(separator: "\n").map { String($0).relative(to: cwd) }.joined(separator: "\n")
    }

    private var sessionLabel: String {
        switch approval.category {
        case .fileChange: return "Allow edits this session"
        case .command: return "Always allow this session"
        default: return "Allow for session"
        }
    }

    private var icon: String {
        switch approval.category {
        case .command: return "terminal"
        case .fileChange: return "pencil"
        case .fileRead: return "doc.text.magnifyingglass"
        case .network: return "globe"
        case .tool: return "wrench.and.screwdriver"
        case .permissions: return "lock.open"
        }
    }
}

/// One question at a time; number keys pick options.
private struct QuestionsPanel: View {
    let questions: [AgentQuestion]
    let submit: ([String: [String]]) -> Void
    @State private var index = 0
    @State private var answers: [String: [String]] = [:]
    @State private var selection: Set<String> = []
    @State private var freeform = ""

    var body: some View {
        // Providers answer an empty list themselves; never index into one.
        if !questions.isEmpty {
            panel(questions[min(index, questions.count - 1)])
        }
    }

    private func panel(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble").foregroundStyle(.orange)
                Text(question.header ?? "Question").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if questions.count > 1 {
                    Text("\(index + 1) of \(questions.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Text(question.prompt).font(.system(size: 15, weight: .medium)).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { offset, option in
                    optionRow(option, number: offset + 1, question: question)
                }
            }
            if question.allowsFreeform {
                TextField(question.options.isEmpty ? "Your answer" : "Something else…", text: $freeform)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { advance(question) }
            }
            HStack {
                Spacer()
                Button(index == questions.count - 1 ? "Submit" : "Next") { advance(question) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty && freeform.nonBlank == nil)
            }
        }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1, n <= question.options.count else { return .ignored }
            toggle(question.options[n - 1].label, question: question)
            if !question.allowsMultiple { advance(question) }
            return .handled
        }
    }

    private func optionRow(_ option: AgentQuestion.Option, number: Int, question: AgentQuestion) -> some View {
        let selected = selection.contains(option.label)
        return Button {
            toggle(option.label, question: question)
            if !question.allowsMultiple { advance(question) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number)")
                    .monoFont(size: 13, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(.system(size: 15))
                    if let description = option.description, !description.isEmpty {
                        Text(description).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ label: String, question: AgentQuestion) {
        if question.allowsMultiple {
            if selection.contains(label) { selection.remove(label) } else { selection.insert(label) }
        } else {
            selection = [label]
        }
    }

    private func advance(_ question: AgentQuestion) {
        var answer = question.options.map(\.label).filter(selection.contains)
        if let text = freeform.nonBlank { answer.append(text) }
        guard !answer.isEmpty else { return }
        answers[question.id] = answer
        selection = []
        freeform = ""
        if index + 1 < questions.count {
            index += 1
        } else {
            submit(answers)
        }
    }
}

private struct PlanApprovalPanel: View {
    let defaultMode: AgentRuntimeMode
    let decide: (AgentPlanDecision) -> Void
    @State private var feedback = ""
    @State private var mode: AgentRuntimeMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard").foregroundStyle(.orange)
                Text("The plan is ready").font(.system(size: 15, weight: .semibold))
            }
            TextField("Feedback to keep planning (optional)", text: $feedback)
                .textFieldStyle(.roundedBorder)
                .onSubmit { decide(.keepPlanning(feedback: feedback.nonBlank)) }
            HStack(spacing: 8) {
                Picker("Implement in", selection: Binding(get: { mode ?? defaultMode }, set: { mode = $0 })) {
                    ForEach(AgentRuntimeMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                    }
                }
                .fixedSize()
                Spacer()
                Button("Keep planning") { decide(.keepPlanning(feedback: feedback.nonBlank)) }
                    .keyboardShortcut(.cancelAction)
                Button("Implement") { decide(.implement(mode: mode ?? defaultMode)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
