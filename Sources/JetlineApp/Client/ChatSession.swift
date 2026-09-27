#if os(macOS)
import Foundation
import Observation

/// The client's view of one engine chat (`ChatEngine`): a mirror kept
/// current by `ChatPatch`es, with the same surface the chat views have
/// always used. Actions go to the engine as `ChatCommand`s; nothing here
/// talks to an agent directly.
///
/// Turns and items are the shared `ChatTurn` / `ChatItemBox` classes, kept
/// by identity across patches so a streaming delta re-renders only its row.
/// The composer's draft is client-local.
@MainActor
@Observable
final class ChatSession: Identifiable {
    typealias Connection = ChatConnection
    typealias Activity = ChatActivity
    typealias QueuedMessage = ChatQueuedMessage
    typealias RemoteControl = ChatRemoteControl

    let id: String
    let workspaceId: String
    private(set) var cwd: String
    private(set) var provider: AgentProviderKind
    private(set) var createdAt: Date

    private(set) var title: String
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var resolvedModel: String?
    private(set) var runtimeMode: AgentRuntimeMode = .supervised
    private(set) var interactionMode: AgentInteractionMode = .normal
    private(set) var connection: Connection = .disconnected
    private(set) var remoteControl: RemoteControl = .off
    private(set) var turns: [ChatTurn] = []
    private(set) var requests: [AgentRequest] = []
    private(set) var todos: [AgentTodo] = []
    private(set) var usage: AgentTokenUsage?
    private(set) var models: [AgentModelOption] = []
    private(set) var commands: [AgentSlashCommand] = []
    private(set) var queued: [QueuedMessage] = []
    /// The engine's banner (a failed revert, say) or one from this client
    /// (an upload that failed). Setting nil dismisses both.
    var banner: String? {
        get { localBanner ?? engineBanner }
        set {
            localBanner = newValue
            if newValue == nil, engineBanner != nil {
                engineBanner = nil
                command(.dismissBanner)
            }
        }
    }
    private var engineBanner: String?
    private var localBanner: String?
    /// Composer contents, kept here so switching tabs doesn't lose a draft.
    var draft = ""
    var draftImages: [URL] = []
    private(set) var isReverting = false
    private(set) var canRevert = true
    private(set) var terminalResumeArgs: [String]?
    /// Whether the transcript has arrived (the first full patch).
    private(set) var isLoaded = false
    /// Summary state from the workspace status, shown before the transcript
    /// loads (tab strip, sidebar).
    private var summaryActivity: Activity = .idle

    @ObservationIgnored private weak var backend: EngineConnection?
    @ObservationIgnored private var boxesById: [String: ChatItemBox] = [:]
    @ObservationIgnored private var turnsById: [String: ChatTurn] = [:]
    @ObservationIgnored private var subscribed = false
    @ObservationIgnored private let files: EngineFiles

    init(summary: ChatSummary, workspaceId: String, cwd: String, backend: EngineConnection, files: EngineFiles) {
        self.id = summary.id
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.provider = summary.provider
        self.title = summary.title
        self.createdAt = Date()
        self.summaryActivity = summary.activity
        self.backend = backend
        self.files = files
    }

    // MARK: - Derived state

    var activeTurn: ChatTurn? {
        turns.last(where: { $0.status == .running })
    }

    var isWorking: Bool { isLoaded ? activeTurn != nil : summaryActivity == .working }

    var activity: Activity {
        guard isLoaded else { return summaryActivity }
        if !requests.isEmpty { return .needsInput }
        if isWorking { return .working }
        if case .failed = connection { return .failed }
        return .idle
    }

    var supportsRemoteControl: Bool { provider == .claude }

    func item(for request: AgentRequest) -> AgentItem? {
        request.itemId.flatMap { itemId in
            turns.lazy.flatMap(\.items).first { $0.item.id == itemId }?.item
        }
    }

    var modelOption: AgentModelOption? {
        let id = model ?? models.first(where: \.isDefault)?.id
        return models.first { $0.id == id }
    }

    // MARK: - Sync

    /// Start receiving the transcript. Idempotent; re-sent after a reconnect.
    func subscribe() {
        guard !subscribed, let backend, backend.isConnected else { return }
        subscribed = true
        let id = self.id
        Task { [weak self] in
            do {
                let full = try await backend.call(API.SubscribeChat(chatId: id))
                self?.apply(full)
            } catch {
                self?.subscribed = false
                self?.banner = (error as? WireError)?.message ?? error.localizedDescription
            }
        }
    }

    func unsubscribe() {
        guard subscribed else { return }
        subscribed = false
        backend?.send(API.UnsubscribeChat(chatId: id))
    }

    /// The link dropped: whatever arrives after a reconnect is a fresh
    /// full patch.
    func markStale() {
        subscribed = false
    }

    func applySummary(_ summary: ChatSummary) {
        summaryActivity = summary.activity
        if !isLoaded, title != summary.title { title = summary.title }
    }

    func apply(_ patch: ChatPatch) {
        if patch.full {
            turns = []
            turnsById.removeAll()
            boxesById.removeAll()
        }
        if let meta = patch.meta { applyMeta(meta) }

        for tm in patch.turns {
            let turn = turnsById[tm.id] ?? {
                let turn = ChatTurn(id: tm.id, seq: tm.seq, status: ChatTurn.Status(rawValue: tm.status) ?? .completed, startedAt: tm.startedAt)
                turnsById[tm.id] = turn
                return turn
            }()
            let status = ChatTurn.Status(rawValue: tm.status) ?? .completed
            if turn.status != status { turn.status = status }
            if turn.providerTurnId != tm.providerTurnId { turn.providerTurnId = tm.providerTurnId }
            if turn.errorMessage != tm.errorMessage { turn.errorMessage = tm.errorMessage }
            if turn.startedAt != tm.startedAt { turn.startedAt = tm.startedAt }
            if turn.completedAt != tm.completedAt { turn.completedAt = tm.completedAt }
            if turn.checkpointBefore != tm.checkpointBefore { turn.checkpointBefore = tm.checkpointBefore }
            if turn.checkpointAfter != tm.checkpointAfter { turn.checkpointAfter = tm.checkpointAfter }
            if turn.stat != tm.stat { turn.stat = tm.stat }
            pendingItemOrder[tm.id] = tm.itemIds
        }

        for change in patch.items {
            switch change {
            case let .upsert(wire):
                if let box = boxesById[wire.boxId] {
                    box.item = wire.item
                } else {
                    boxesById[wire.boxId] = ChatItemBox(id: wire.boxId, item: wire.item, createdAt: wire.createdAt)
                }
                prefetchImages(of: wire.item)
            case let .append(boxId, kind, text):
                boxesById[boxId]?.item.append(text, kind: kind)
            }
        }

        // Item membership/order per turn, now that every box exists.
        for (turnId, itemIds) in pendingItemOrder {
            guard let turn = turnsById[turnId] else { continue }
            let boxes = itemIds.compactMap { boxesById[$0] }
            if turn.items.map(\.id) != boxes.map(\.id) { turn.items = boxes }
        }
        pendingItemOrder.removeAll()

        if let order = patch.turnOrder {
            let live = Set(order)
            for id in turnsById.keys where !live.contains(id) {
                if let turn = turnsById.removeValue(forKey: id) {
                    for box in turn.items { boxesById.removeValue(forKey: box.id) }
                }
            }
            let newTurns = order.compactMap { turnsById[$0] }
            if turns.map(\.id) != newTurns.map(\.id) { turns = newTurns }
        }
        isLoaded = true
    }

    @ObservationIgnored private var pendingItemOrder: [String: [String]] = [:]

    private func applyMeta(_ meta: ChatMeta) {
        if cwd != meta.cwd { cwd = meta.cwd }
        if provider != meta.provider { provider = meta.provider }
        if createdAt != meta.createdAt { createdAt = meta.createdAt }
        if title != meta.title { title = meta.title }
        if model != meta.model { model = meta.model }
        if effort != meta.effort { effort = meta.effort }
        if resolvedModel != meta.resolvedModel { resolvedModel = meta.resolvedModel }
        if runtimeMode != meta.runtimeMode { runtimeMode = meta.runtimeMode }
        if interactionMode != meta.interactionMode { interactionMode = meta.interactionMode }
        if connection != meta.connection { connection = meta.connection }
        if remoteControl != meta.remoteControl { remoteControl = meta.remoteControl }
        if requests != meta.requests { requests = meta.requests }
        if todos != meta.todos { todos = meta.todos }
        if usage != meta.usage { usage = meta.usage }
        if models != meta.models { models = meta.models }
        if commands != meta.commands { commands = meta.commands }
        if queued != meta.queued { queued = meta.queued }
        if engineBanner != meta.banner { engineBanner = meta.banner }
        if isReverting != meta.isReverting { isReverting = meta.isReverting }
        if canRevert != meta.canRevert { canRevert = meta.canRevert }
        if terminalResumeArgs != meta.terminalResumeArgs { terminalResumeArgs = meta.terminalResumeArgs }
    }

    private func prefetchImages(of item: AgentItem) {
        guard case let .userMessage(message) = item.content, !message.images.isEmpty else { return }
        for path in message.images { files.prefetch(path) }
    }

    // MARK: - Actions

    private func command(_ command: API.ChatCommand.Command) {
        guard let backend else { return }
        let id = self.id
        Task { [weak self] in
            do {
                _ = try await backend.call(API.ChatCommand(chatId: id, command: command))
            } catch {
                guard let self else { return }
                self.banner = (error as? WireError)?.message ?? error.localizedDescription
                // An optimistic change here (a dismissed request, a new
                // mode) didn't happen: take the engine's state again.
                self.subscribed = false
                self.subscribe()
            }
        }
    }

    /// Start the agent process if it isn't running (the engine makes it a
    /// no-op when it is — and a retry after a failed start when it isn't).
    func connectIfNeeded() {
        command(.connect)
    }

    func disconnect() {
        command(.disconnect)
    }

    func send(text: String, images: [URL] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        banner = nil
        guard let backend, backend.isConnected else {
            restoreDraft(text, images)
            banner = WireError.disconnected.message
            return
        }
        let id = self.id
        let files = self.files
        // Sends go out in order even when one waits on image uploads.
        let previous = sendChain
        sendChain = Task { [weak self] in
            await previous?.value
            do {
                // Images go to the engine's disk first; the agent reads them
                // there.
                var paths: [String] = []
                for image in images {
                    paths.append(try await files.upload(image))
                }
                _ = try await backend.call(API.ChatCommand(chatId: id, command: .send(text: text, images: paths)))
            } catch {
                self?.restoreDraft(text, images)
                self?.banner = (error as? WireError)?.message ?? error.localizedDescription
            }
        }
    }

    @ObservationIgnored private var sendChain: Task<Void, Never>?

    /// A message that didn't go out goes back in the composer.
    private func restoreDraft(_ text: String, _ images: [URL]) {
        if draft.isEmpty { draft = text }
        if draftImages.isEmpty { draftImages = images }
    }

    func removeQueued(_ message: QueuedMessage) {
        queued.removeAll { $0.id == message.id }
        command(.removeQueued(id: message.id))
    }

    func interrupt() {
        command(.interrupt)
    }

    func respond(to request: AgentRequest, with decision: AgentApprovalDecision) {
        requests.removeAll { $0.id == request.id }
        command(.respond(requestId: request.id, decision: decision))
    }

    func answer(_ request: AgentRequest, answers: [String: [String]]) {
        requests.removeAll { $0.id == request.id }
        command(.answer(requestId: request.id, answers: answers))
    }

    func resolvePlan(_ request: AgentRequest, with decision: AgentPlanDecision) {
        requests.removeAll { $0.id == request.id }
        command(.resolvePlan(requestId: request.id, decision: decision))
    }

    func setRuntimeMode(_ mode: AgentRuntimeMode) {
        runtimeMode = mode
        command(.setRuntimeMode(mode))
    }

    func setInteractionMode(_ mode: AgentInteractionMode) {
        interactionMode = mode
        command(.setInteractionMode(mode))
    }

    func setModel(_ model: String?, effort: String?) {
        self.model = model
        self.effort = effort
        command(.setModel(model: model, effort: effort))
    }

    func setRemoteControl(_ enabled: Bool) {
        command(.setRemoteControl(enabled))
    }

    /// Put the worktree back to before `turn` and drop it (and everything
    /// after) from the conversation. The turn's message returns to the
    /// composer so it can be edited and resent.
    func revert(to turn: ChatTurn) {
        guard !isReverting, let backend else { return }
        banner = nil
        let id = self.id
        let files = self.files
        Task { [weak self] in
            do {
                let result = try await backend.call(API.ChatCommand(chatId: id, command: .revert(turnId: turn.id)))
                guard let self, let draft = result.draft else { return }
                self.draft = draft
                self.draftImages = (result.draftImages ?? []).compactMap { files.localURL(for: $0) }
            } catch {
                self?.banner = (error as? WireError)?.message ?? error.localizedDescription
            }
        }
    }
}
#endif
