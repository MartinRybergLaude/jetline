import Foundation
import Observation

/// One row of the timeline: a value snapshot of what it shows, so the
/// table can tell exactly which rows changed.
struct ChatRow: Equatable {
    enum Content: Equatable {
        case spacer(CGFloat)
        case user(text: String, images: [String], timestamp: Date?, canRevert: Bool)
        /// `copyText` is set on the message that ends a finished reply: it
        /// alone shows the actions, and copies the whole reply.
        case assistant(text: String, timestamp: Date?, streaming: Bool, copyText: String?)
        /// Consecutive tool calls and reasoning.
        case work(items: [AgentItem], isLive: Bool)
        case plan(String)
        case notice(AgentItem.Notice)
        case compaction
        case footer(Footer)
    }

    /// Below each turn: how long it has run, live while it runs (`until`
    /// nil, with its `activity`), then what it changed or how it ended.
    enum Footer: Equatable {
        case status(since: Date, until: Date?, activity: Activity?, agent: AgentProviderKind)
        case changes(stat: Checkpointer.Stat, from: String, to: String)
        case interrupted
        case failed(String)
    }

    /// What a running turn is doing right now.
    enum Activity: Equatable {
        case waitingForAgent
        case thinking
        case writing
        case runningTools
        case waitingForYou
    }

    let id: String
    let turnId: String
    var content: Content
    /// Space below the row.
    var gap: CGFloat = 0
    /// The gap starts below the row's hover bar rather than sharing its
    /// space.
    var gapClearsBar = false
    /// Keeps a message's actions shown without hover: the conversation's
    /// last reply.
    var pinsActions = false

    /// Views of rows of the same kind share structure, so the table reuses
    /// them within a kind.
    var reuseKind: String {
        switch content {
        case .spacer: return "spacer"
        case .user: return "user"
        case .assistant: return "assistant"
        case .work: return "work"
        case .plan: return "plan"
        case .notice: return "notice"
        case .compaction: return "compaction"
        case .footer: return "footer"
        }
    }
}

/// Folds a session's observable turns into rows. Each turn's rows are
/// built under their own observation, so a streaming delta rebuilds only
/// the turn it lands in.
@MainActor
final class ChatTimelineModel {
    static let turnSpacing: CGFloat = 40
    static let itemSpacing: CGFloat = 26
    /// Around tool call groups, whose one-line headers need less air.
    static let workSpacing: CGFloat = 20
    /// Above the status row, so it reads apart from the reply.
    static let statusSpacing: CGFloat = 26
    static let topPadding: CGFloat = 52
    static let bottomPadding: CGFloat = 20
    private static let statusPrefix = "status-"

    private let session: ChatSession
    private var turns: [ChatTurn] = []
    private var turnsDirty = true
    /// By turn id; the turn is kept to tell a rebuilt turn object apart.
    private var cache: [String: (turn: ChatTurn, rows: [ChatRow])] = [:]
    private var dirty: Set<String> = []
    private var notifyScheduled = false
    /// Called, coalesced, after anything the rows read changed.
    var onChange: (() -> Void)?

    init(session: ChatSession) {
        self.session = session
    }

    var isEmpty: Bool { turns.isEmpty }

    func rows() -> [ChatRow] {
        if turnsDirty {
            turnsDirty = false
            turns = withObservationTracking { session.turns } onChange: { [weak self] in
                Task { @MainActor in self?.invalidateTurns() }
            }
            let live = Set(turns.map(\.id))
            cache = cache.filter { live.contains($0.key) }
        }
        var rows = [ChatRow(id: "top", turnId: "", content: .spacer(Self.topPadding))]
        for turn in turns {
            let key = turn.id
            if dirty.contains(key) || cache[key]?.turn !== turn {
                let built = withObservationTracking { build(turn) } onChange: { [weak self] in
                    Task { @MainActor in self?.invalidate(key) }
                }
                cache[key] = (turn, built)
            }
            rows += cache[key]?.rows ?? []
        }
        dirty.removeAll()
        rows.append(ChatRow(id: "bottom", turnId: "", content: .spacer(Self.bottomPadding)))
        // Only the last turn keeps its status row.
        let lastTurn = turns.last?.id
        rows.removeAll { $0.id.hasPrefix(Self.statusPrefix) && $0.turnId != lastTurn }
        applyGaps(&rows)
        if let last = rows.lastIndex(where: { $0.reuseKind != "spacer" && $0.reuseKind != "footer" }),
           case .assistant(_, _, _, .some) = rows[last].content {
            rows[last].pinsActions = true
        }
        return rows
    }

    private func invalidateTurns() {
        turnsDirty = true
        scheduleNotify()
    }

    private func invalidate(_ key: String) {
        dirty.insert(key)
        scheduleNotify()
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.notifyScheduled = false
                self.onChange?()
            }
        }
    }

    private func build(_ turn: ChatTurn) -> [ChatRow] {
        var rows: [ChatRow] = []
        func add(_ id: String, _ content: ChatRow.Content) {
            rows.append(ChatRow(id: id, turnId: turn.id, content: content))
        }
        let segments = ChatSegment.segments(turn.items)
        for (index, segment) in segments.enumerated() {
            switch segment {
            case let .user(box):
                guard case let .userMessage(message) = box.item.content,
                      !message.text.isEmpty || !message.images.isEmpty else { continue }
                add(box.id, .user(
                    text: message.text,
                    images: message.images,
                    timestamp: box.createdAt ?? turn.startedAt,
                    canRevert: session.canRevert && turn.status != .running && !session.isReverting
                ))
            case let .message(box):
                guard case let .assistantMessage(text) = box.item.content, !text.isEmpty else { continue }
                add(box.id, .assistant(text: text, timestamp: box.createdAt ?? turn.completedAt, streaming: box.item.status == .inProgress, copyText: nil))
            case let .work(boxes):
                add(segment.id, .work(items: boxes.map(\.item), isLive: turn.status == .running && index == segments.count - 1))
            case let .plan(box):
                guard case let .plan(text) = box.item.content, !text.isEmpty else { continue }
                add(box.id, .plan(text))
            case let .notice(box):
                guard case let .notice(notice) = box.item.content else { continue }
                add(box.id, .notice(notice))
            case let .compaction(box):
                add(box.id, .compaction)
            }
        }
        if turn.status != .running { markReplyEnd(&rows) }

        let footerId = Self.statusPrefix + turn.id
        let outcomeId = "outcome-" + turn.id
        if turn.status == .running {
            add(footerId, .footer(.status(
                since: turn.startedAt,
                until: nil,
                activity: activity(of: turn),
                agent: session.provider
            )))
        } else if turn.userMessage != nil, let completedAt = turn.completedAt {
            add(footerId, .footer(.status(
                since: turn.startedAt,
                until: completedAt,
                activity: nil,
                agent: session.provider
            )))
        }
        switch turn.status {
        case .running:
            break
        case .completed:
            if let stat = turn.stat, !stat.isEmpty, let before = turn.checkpointBefore, let after = turn.checkpointAfter {
                add(outcomeId, .footer(.changes(stat: stat, from: before, to: after)))
            }
        case .interrupted:
            add(outcomeId, .footer(.interrupted))
        case .failed:
            add(outcomeId, .footer(.failed(turn.errorMessage ?? "The turn failed.")))
        }
        return rows
    }

    private func activity(of turn: ChatTurn) -> ChatRow.Activity {
        if !session.requests.isEmpty { return .waitingForYou }
        guard let box = turn.items.last(where: { $0.item.status == .inProgress }) else { return .waitingForAgent }
        switch box.item.content {
        case .reasoning: return .thinking
        case .assistantMessage: return .writing
        default: return box.kind == .work ? .runningTools : .waitingForAgent
        }
    }

    /// Gives the reply's last row, if it is a message, the text of every
    /// message since the user's.
    private func markReplyEnd(_ rows: inout [ChatRow]) {
        guard let last = rows.indices.last,
              case let .assistant(text, timestamp, streaming, _) = rows[last].content else { return }
        var texts: [String] = []
        for row in rows.reversed() {
            if case .user = row.content { break }
            if case let .assistant(text, _, _, _) = row.content { texts.append(text) }
        }
        rows[last].content = .assistant(text: text, timestamp: timestamp, streaming: streaming, copyText: texts.reversed().joined(separator: "\n\n"))
    }

    /// Items within a turn sit `itemSpacing` apart (`workSpacing` next to a
    /// tool call group), turns `turnSpacing`. A
    /// user message gets the turn gap below it too.
    private func applyGaps(_ rows: inout [ChatRow]) {
        for index in rows.indices {
            if case .spacer = rows[index].content { continue }
            let next = index + 1 < rows.count ? rows[index + 1] : nil
            var gap: CGFloat = 0
            if let next {
                if next.turnId == rows[index].turnId {
                    gap = rows[index].reuseKind == "work" || next.reuseKind == "work" ? Self.workSpacing : Self.itemSpacing
                } else if case .spacer = next.content {
                    gap = 0
                } else {
                    gap = Self.turnSpacing
                }
            }
            if case .user = rows[index].content { gap += Self.turnSpacing - Self.itemSpacing }
            if let next, next.id.hasPrefix(Self.statusPrefix) {
                gap = Self.statusSpacing
                rows[index].gapClearsBar = true
            }
            rows[index].gap = gap
        }
    }
}
