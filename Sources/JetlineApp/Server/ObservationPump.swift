import Foundation
import Observation

@MainActor
protocol Pump: AnyObject {
    func start()
    func stop()
    func flush()
}

/// Watches whatever `read` touches on `@Observable` objects and calls
/// `emit` with a fresh value after it changes — coalesced over `delay`, and
/// skipped when the new value equals the last one emitted. The server uses
/// one per published slice of engine state.
@MainActor
final class ObservationPump<Value: Equatable>: Pump {
    private let read: @MainActor () -> Value
    private let emit: @MainActor (Value) -> Void
    private let delay: Duration
    private var scheduled = false
    private var stopped = false
    private(set) var current: Value?

    init(delay: Duration = .milliseconds(30), read: @escaping @MainActor () -> Value, emit: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.emit = emit
        self.delay = delay
    }

    /// Start tracking. The first value is taken as the baseline, not emitted.
    func start() {
        current = track()
    }

    func stop() {
        stopped = true
    }

    /// Emit a pending change now instead of after the delay.
    func flush() {
        guard scheduled, !stopped else { return }
        scheduled = false
        pump()
    }

    private func track() -> Value {
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            // Called synchronously from the mutating code, before the new
            // value lands; hop so the read sees it.
            Task { @MainActor [weak self] in self?.schedule() }
        }
    }

    private func schedule() {
        guard !scheduled, !stopped else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.delay)
            guard self.scheduled, !self.stopped else { return }
            self.scheduled = false
            self.pump()
        }
    }

    private func pump() {
        let value = track()
        guard value != current else { return }
        current = value
        emit(value)
    }
}

/// Turns a `ChatEngine`'s state into `ChatPatch`es: a full one for a new
/// subscriber, then only what changed. Streaming text becomes `append`
/// changes, so a long answer isn't re-sent whole on every flush.
@MainActor
final class ChatPublisher {
    let chat: ChatEngine
    private var pump: ObservationPump<Int>?
    private var version = 0
    private var lastMeta: ChatMeta?
    private var lastTurnOrder: [String] = []
    private var lastTurns: [String: ChatTurnMeta] = [:]
    private var lastItems: [String: AgentItem] = [:]
    private let emit: @MainActor (ChatPatch) -> Void

    init(chat: ChatEngine, emit: @escaping @MainActor (ChatPatch) -> Void) {
        self.chat = chat
        self.emit = emit
    }

    func start() {
        // The pump's value is a change counter: `read` walks the whole
        // chat (registering observation on all of it) and records whether
        // anything differs from the baseline.
        let pump = ObservationPump<Int>(delay: .milliseconds(50)) { [weak self] in
            guard let self else { return 0 }
            self.touchAll()
            return self.version
        } emit: { _ in }
        _ = fullPatch()
        self.pump = pump
        // Takes the baseline (no diff yet); later changes re-run `touchAll`,
        // which diffs and emits.
        pump.start()
    }

    func stop() {
        pump?.stop()
        pump = nil
    }

    /// Everything, as the new baseline. Pending changes go out first so
    /// existing subscribers don't miss them.
    func fullPatch() -> ChatPatch {
        // Diff against the old baseline first, so subscribers already here
        // get whatever changed since — even if the pump hasn't noticed yet.
        if pump != nil { touchAll() }
        let meta = chat.meta
        var turns: [ChatTurnMeta] = []
        var items: [ChatItemChange] = []
        lastItems.removeAll(keepingCapacity: true)
        lastTurns.removeAll(keepingCapacity: true)
        for turn in chat.turns {
            let tm = Self.turnMeta(turn)
            turns.append(tm)
            lastTurns[turn.id] = tm
            for box in turn.items {
                items.append(.upsert(ChatItemWire(boxId: box.id, item: box.item, createdAt: box.createdAt)))
                lastItems[box.id] = box.item
            }
        }
        lastMeta = meta
        lastTurnOrder = chat.turns.map(\.id)
        return ChatPatch(full: true, meta: meta, turnOrder: lastTurnOrder, turns: turns, items: items)
    }

    /// Read everything observable (so the pump re-arms on any change) and
    /// emit the difference from the baseline.
    private func touchAll() {
        var patch = ChatPatch(full: false, meta: nil, turnOrder: nil, turns: [], items: [])
        let meta = chat.meta
        if meta != lastMeta {
            patch.meta = meta
            lastMeta = meta
        }
        let order = chat.turns.map(\.id)
        if order != lastTurnOrder {
            patch.turnOrder = order
            let live = Set(order)
            for id in lastTurns.keys where !live.contains(id) { lastTurns.removeValue(forKey: id) }
            lastTurnOrder = order
        }
        var liveItems = Set<String>()
        for turn in chat.turns {
            let tm = Self.turnMeta(turn)
            if lastTurns[turn.id] != tm {
                patch.turns.append(tm)
                lastTurns[turn.id] = tm
            }
            for box in turn.items {
                liveItems.insert(box.id)
                let item = box.item
                guard let previous = lastItems[box.id] else {
                    patch.items.append(.upsert(ChatItemWire(boxId: box.id, item: item, createdAt: box.createdAt)))
                    lastItems[box.id] = item
                    continue
                }
                guard previous != item else { continue }
                if let (kind, suffix) = item.streamedSuffix(since: previous) {
                    patch.items.append(.append(boxId: box.id, kind: kind, text: suffix))
                } else {
                    patch.items.append(.upsert(ChatItemWire(boxId: box.id, item: item, createdAt: box.createdAt)))
                }
                lastItems[box.id] = item
            }
        }
        if lastItems.count != liveItems.count {
            for id in lastItems.keys where !liveItems.contains(id) { lastItems.removeValue(forKey: id) }
        }
        guard patch.meta != nil || patch.turnOrder != nil || !patch.turns.isEmpty || !patch.items.isEmpty else { return }
        version &+= 1
        emit(patch)
    }

    static func turnMeta(_ turn: ChatTurn) -> ChatTurnMeta {
        ChatTurnMeta(
            id: turn.id,
            seq: turn.seq,
            providerTurnId: turn.providerTurnId,
            status: turn.status.rawValue,
            errorMessage: turn.errorMessage,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            checkpointBefore: turn.checkpointBefore,
            checkpointAfter: turn.checkpointAfter,
            stat: turn.stat,
            itemIds: turn.items.map(\.id)
        )
    }
}

extension ChatEngine {
    var meta: ChatMeta {
        ChatMeta(
            id: id,
            workspaceId: workspaceId,
            cwd: cwd,
            provider: provider,
            createdAt: createdAt,
            title: title,
            model: model,
            effort: effort,
            resolvedModel: resolvedModel,
            runtimeMode: runtimeMode,
            interactionMode: interactionMode,
            connection: connection,
            remoteControl: remoteControl,
            requests: requests,
            todos: todos,
            usage: usage,
            models: models,
            commands: commands,
            queued: queued,
            banner: banner,
            isReverting: isReverting,
            canRevert: canRevert,
            terminalResumeArgs: terminalResumeArgs
        )
    }
}

extension AgentItem {
    /// When `self` is `previous` with text appended to its streaming field
    /// (and nothing else changed), the field and the appended text.
    func streamedSuffix(since previous: AgentItem) -> (AgentStreamKind, String)? {
        guard id == previous.id, turnId == previous.turnId, parentId == previous.parentId,
              status == previous.status else { return nil }
        func suffix(_ new: String, _ old: String) -> String? {
            guard new.utf8.count > old.utf8.count, new.hasPrefix(old) else { return nil }
            return String(decoding: new.utf8.dropFirst(old.utf8.count), as: UTF8.self)
        }
        switch (content, previous.content) {
        case let (.assistantMessage(new), .assistantMessage(old)):
            return suffix(new, old).map { (.assistantText, $0) }
        case let (.reasoning(new), .reasoning(old)):
            return suffix(new, old).map { (.reasoningText, $0) }
        case let (.plan(new), .plan(old)):
            return suffix(new, old).map { (.planText, $0) }
        case let (.command(new), .command(old)):
            var rebuilt = old
            rebuilt.output = new.output
            guard rebuilt == new else { return nil }
            return suffix(new.output, old.output).map { (.commandOutput, $0) }
        case let (.tool(new), .tool(old)):
            var rebuilt = old
            rebuilt.output = new.output
            guard rebuilt == new else { return nil }
            return suffix(new.output ?? "", old.output ?? "").map { (.toolOutput, $0) }
        default:
            return nil
        }
    }
}
