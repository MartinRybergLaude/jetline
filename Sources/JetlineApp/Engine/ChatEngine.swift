import Foundation
import Observation

/// One timeline entry. A class so a streaming item re-renders only its own
/// row: text deltas mutate `item`, not the turn's item list.
@MainActor
@Observable
final class ChatItemBox: Identifiable {
    /// How the timeline lays an item out. Fixed at creation — an item's
    /// content kind never changes — so the turn view can group rows by it
    /// without observing `item`, and a streaming delta re-renders only the
    /// row it lands in.
    enum Kind {
        case user
        case message
        case reasoning
        case work
        case plan
        case notice
        case compaction
    }

    /// Stable local id. The item's own id can change once (an optimistic
    /// user message adopting the provider's id).
    let id: String
    let kind: Kind
    var item: AgentItem
    /// When the item first appeared. `nil` for items saved before this was
    /// recorded.
    let createdAt: Date?

    init(id: String, item: AgentItem, createdAt: Date? = Date()) {
        self.id = id
        self.item = item
        self.createdAt = createdAt
        switch item.content {
        case .userMessage: kind = .user
        case .assistantMessage: kind = .message
        case .reasoning: kind = .reasoning
        case .command, .fileChange, .tool, .webSearch, .subagent: kind = .work
        case .plan: kind = .plan
        case .notice: kind = .notice
        case .compaction: kind = .compaction
        }
    }
}

@MainActor
@Observable
final class ChatTurn: Identifiable {
    enum Status: String {
        case running
        case completed
        case interrupted
        case failed
    }

    let id: String
    let seq: Int
    /// The provider's id for the turn, once it has started.
    var providerTurnId: String?
    var status: Status
    var errorMessage: String?
    var items: [ChatItemBox] = []
    var startedAt: Date
    var completedAt: Date?
    var checkpointBefore: String?
    var checkpointAfter: String?
    var stat: Checkpointer.Stat?

    init(id: String, seq: Int, status: Status, startedAt: Date = Date()) {
        self.id = id
        self.seq = seq
        self.status = status
        self.startedAt = startedAt
    }

    var userMessage: AgentItem.UserMessage? {
        for box in items {
            if case let .userMessage(message) = box.item.content { return message }
        }
        return nil
    }
}

/// A native chat with one agent, engine side: owns the provider, folds its
/// events into observable state, persists the transcript and snapshots the
/// worktree around every turn. Clients see it through `ChatPublisher`'s
/// patches (the client-side mirror is `ChatSession`).
@MainActor
@Observable
final class ChatEngine: Identifiable {
    typealias Connection = ChatConnection
    /// What the tab strip and sidebar show.
    typealias Activity = ChatActivity
    typealias QueuedMessage = ChatQueuedMessage

    let id: String
    let workspaceId: String
    let cwd: String
    let provider: AgentProviderKind
    let createdAt: Date

    var title: String
    /// Model the user picked; nil → CLI default.
    private(set) var model: String?
    private(set) var effort: String?
    /// Model the CLI reports it's actually using.
    private(set) var resolvedModel: String?
    private(set) var runtimeMode: AgentRuntimeMode
    private(set) var interactionMode: AgentInteractionMode

    private(set) var connection: Connection = .disconnected
    /// Remote Control: continuing this chat from claude.ai or the Claude
    /// app. Not kept across restarts.
    private(set) var remoteControl: ChatRemoteControl = .off
    private(set) var turns: [ChatTurn] = []
    private(set) var requests: [AgentRequest] = []
    private(set) var todos: [AgentTodo] = []
    private(set) var usage: AgentTokenUsage?
    private(set) var models: [AgentModelOption] = []
    private(set) var commands: [AgentSlashCommand] = []
    private(set) var queued: [QueuedMessage] = []
    /// Transient problem shown above the composer (send failed, revert
    /// failed). Cleared on the next successful action.
    var banner: String?
    /// True while a revert restores files and truncates the conversation.
    private(set) var isReverting = false

    @ObservationIgnored private var resume: AgentResumeCursor?
    @ObservationIgnored private var agent: (any AgentProvider)?
    @ObservationIgnored private var capabilities: AgentCapabilities?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Bumped whenever the agent is replaced or dropped, so events still in
    /// flight from an old process are ignored.
    @ObservationIgnored private var agentGeneration = 0
    /// Set once the session is dropped (tab closed, workspace torn down):
    /// from then on nothing writes to the database or checkpoint refs.
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    @ObservationIgnored private var boxesByItemId: [String: ChatItemBox] = [:]
    @ObservationIgnored private var turnsByProviderId: [String: ChatTurn] = [:]
    /// Optimistic turn created on send, waiting for the provider's
    /// `turnStarted`.
    @ObservationIgnored private var pendingTurn: ChatTurn?
    /// The turn whose `send` is in flight. Stopped meanwhile, it's no
    /// longer pending but still adopts the provider turn the send starts,
    /// so that turn doesn't show up as a new one.
    @ObservationIgnored private var sendingTurn: ChatTurn?
    @ObservationIgnored private var pendingDeltas: [(itemId: String, turnId: String?, kind: AgentStreamKind, text: String)] = []
    @ObservationIgnored private var deltaFlushTask: Task<Void, Never>?
    @ObservationIgnored private var itemSeq = 0
    @ObservationIgnored private var executableResolver: (AgentProviderKind) async -> String?
    @ObservationIgnored private let rateLimits: AgentRateLimits

    /// Fired when a turn finishes or starts waiting on the user, so the app
    /// can badge or notify.
    @ObservationIgnored var onAttention: ((ChatEngine) -> Void)?
    /// Fired after each completed turn (used to refresh the diff panel).
    @ObservationIgnored var onTurnFinished: ((ChatEngine) -> Void)?

    // MARK: - Init

    /// A new chat.
    init(
        workspaceId: String,
        cwd: String,
        provider: AgentProviderKind,
        model: String?,
        effort: String?,
        runtimeMode: AgentRuntimeMode,
        rateLimits: AgentRateLimits,
        executableResolver: @escaping (AgentProviderKind) async -> String?
    ) {
        self.rateLimits = rateLimits
        self.id = UUID().uuidString.lowercased()
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.provider = provider
        self.createdAt = Date()
        self.title = "New chat"
        self.model = model
        self.effort = effort
        self.runtimeMode = runtimeMode
        self.interactionMode = .normal
        self.executableResolver = executableResolver
        persistThread()
    }

    /// A chat restored from the database.
    init(
        record: ChatThreadRecord,
        cwd: String,
        rateLimits: AgentRateLimits,
        executableResolver: @escaping (AgentProviderKind) async -> String?
    ) {
        self.rateLimits = rateLimits
        self.id = record.id
        self.workspaceId = record.workspaceId
        self.cwd = cwd
        self.provider = record.provider
        self.createdAt = record.createdAt
        self.title = record.title
        self.model = record.model
        self.effort = record.effort
        self.runtimeMode = record.runtimeMode
        self.interactionMode = record.interactionMode
        self.executableResolver = executableResolver
        self.resume = record.resumeCursor.flatMap { try? ChatStore.decoder.decode(AgentResumeCursor.self, from: Data($0.utf8)) }
        self.todos = record.todos.flatMap { try? ChatStore.decoder.decode([AgentTodo].self, from: Data($0.utf8)) } ?? []
        loadTranscript()
    }

    // MARK: - Derived state

    var activeTurn: ChatTurn? {
        turns.last(where: { $0.status == .running })
    }

    var isWorking: Bool { activeTurn != nil }

    var activity: Activity {
        if !requests.isEmpty { return .needsInput }
        if isWorking { return .working }
        if case .failed = connection { return .failed }
        return .idle
    }

    var canRevert: Bool { capabilities?.conversationRevert ?? true }
    var supportsRemoteControl: Bool { provider == .claude }

    /// The timeline item a request is about (the tool call awaiting
    /// approval), so the prompt can show its diff or command.
    func item(for request: AgentRequest) -> AgentItem? {
        request.itemId.flatMap { boxesByItemId[$0]?.item }
    }

    /// The agent's session to continue. Nil until a message was sent: the
    /// agent writes nothing before that, so there is nothing to resume.
    private var resumableSession: AgentResumeCursor? {
        guard let resume, !resume.sessionId.isEmpty,
              turns.contains(where: { $0.userMessage != nil }) else { return nil }
        return resume
    }

    /// Arguments that open this conversation in the agent's own TUI.
    var terminalResumeArgs: [String]? {
        guard let id = resumableSession?.sessionId else { return nil }
        switch provider {
        case .claude: return ["--resume", id]
        case .codex: return ["resume", id]
        }
    }

    var modelOption: AgentModelOption? {
        let id = model ?? models.first(where: \.isDefault)?.id
        return models.first { $0.id == id }
    }

    // MARK: - Connection

    /// Start the agent process if it isn't running. Called when the tab is
    /// first shown and before sending.
    func connectIfNeeded() {
        guard agent == nil, connectTask == nil, !isRetired else { return }
        connectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.connectTask = nil }
            try await self.connect()
        }
    }

    private func ensureConnected() async throws {
        if agent != nil, connection == .connected { return }
        connectIfNeeded()
        try await connectTask?.value
        guard agent != nil else { throw AgentError.notRunning }
    }

    private func connect() async throws {
        connection = .connecting
        guard let executable = await executableResolver(provider) else {
            let error = AgentError.executableNotFound(provider.agentKind.executableName)
            connection = .failed(error.localizedDescription)
            throw error
        }
        // Closed while resolving: `retire()` found no agent to stop, so
        // nothing would stop this one.
        guard !isRetired else {
            connection = .disconnected
            throw AgentError.notRunning
        }
        let agent: any AgentProvider = provider == .claude ? ClaudeProvider() : CodexProvider()
        self.agent = agent
        self.capabilities = agent.capabilities
        agentGeneration += 1
        let generation = agentGeneration
        let events = agent.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, self.agentGeneration == generation else { return }
                self.handle(event)
            }
        }
        do {
            try await agent.start(AgentSessionConfig(
                cwd: cwd,
                executable: executable,
                model: model,
                effort: effort,
                runtimeMode: runtimeMode,
                interactionMode: interactionMode,
                resume: resumableSession
            ))
            // Disconnected while starting: nothing else will stop it.
            if generation != agentGeneration {
                await agent.stop()
                throw AgentError.notRunning
            }
        } catch {
            guard generation == agentGeneration else { throw error }
            self.agent = nil
            agentGeneration += 1
            eventTask?.cancel()
            eventTask = nil
            connection = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Stop the agent process. The chat stays; the next message resumes it.
    func disconnect() {
        guard let agent = detachAgent() else { return }
        Task { await agent.stop() }
    }

    /// Drop the agent and settle the chat as if it had stopped on request.
    /// Its remaining events are ignored: a late `exited` would otherwise
    /// clear a newer agent or write rows for a deleted chat.
    private func detachAgent() -> (any AgentProvider)? {
        guard let agent else { return nil }
        flushDeltas()
        agentGeneration += 1
        eventTask?.cancel()
        agentEnded(failure: nil)
        return agent
    }

    /// The agent stopped: `failure` is why, or nil when it was asked to.
    private func agentEnded(failure: String?) {
        agent = nil
        eventTask = nil
        remoteControl = .off
        requests.removeAll()
        connection = failure.map { .failed("\(provider.displayName) stopped: \($0)") } ?? .disconnected
        // A requested stop drops what was queued behind the turn, rather
        // than starting it on a fresh process.
        if failure == nil { queued.removeAll() }
        if let turn = activeTurn {
            finish(turn, outcome: failure.map { .failed(message: $0) } ?? .interrupted)
        }
        // Background agents died with the process.
        for turn in turns {
            for box in turn.items where box.item.status == .inProgress {
                box.item.status = .interrupted
                persistItem(box, in: turn)
            }
        }
    }

    // MARK: - Sending

    func send(text: String, images: [URL] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        banner = nil
        if isWorking {
            // Steer only a turn the agent has started: before that, the
            // message would become a turn of its own.
            if capabilities?.steering == true, let agent, pendingTurn == nil {
                steer(text: text, images: images, agent: agent)
            } else {
                queued.append(QueuedMessage(text: text, images: images.map(\.path)))
            }
            return
        }
        startTurn(text: text, images: images)
    }

    func removeQueued(_ message: QueuedMessage) {
        queued.removeAll { $0.id == message.id }
    }

    private func startTurn(text: String, images: [URL]) {
        let turn = ChatTurn(id: UUID().uuidString.lowercased(), seq: (turns.last?.seq ?? 0) + 1, status: .running)
        let userItem = AgentItem(
            id: "local-\(turn.id)", turnId: nil, status: .completed,
            content: .userMessage(.init(text: text, images: images.map(\.path)))
        )
        let box = ChatItemBox(id: userItem.id, item: userItem)
        turn.items.append(box)
        turns.append(turn)
        pendingTurn = turn
        persistTurn(turn)
        persistItem(box, in: turn)
        if turns.count == 1 || title == "New chat" {
            title = Self.title(from: text)
            persistThread()
        }

        let input = AgentTurnInput(
            text: text, images: images, model: model, effort: effort, interactionMode: interactionMode
        )
        Task { [weak self] in
            guard let self, self.isLive(turn) else { return }
            if let before = await Checkpointer.capture(
                worktree: self.cwd,
                ref: Checkpointer.ref(thread: self.id, turn: String(turn.seq), phase: "before")
            ) {
                turn.checkpointBefore = before
                self.persistTurn(turn)
            }
            // Stopped (or reverted) while the snapshot was taken.
            guard turn.status == .running, self.isLive(turn) else { return }
            do {
                try await self.ensureConnected()
                // Stopped (or reverted) while the agent was starting.
                guard turn.status == .running, self.isLive(turn) else { return }
                guard let agent = self.agent else { throw AgentError.notRunning }
                self.sendingTurn = turn
                defer { if self.sendingTurn === turn { self.sendingTurn = nil } }
                try await agent.send(input)
            } catch {
                self.failPendingTurn(turn, error)
            }
        }
    }

    private func steer(text: String, images: [URL], agent: any AgentProvider) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await agent.send(AgentTurnInput(
                    text: text, images: images, model: self.model, effort: self.effort,
                    interactionMode: self.interactionMode
                ))
            } catch {
                self.banner = error.localizedDescription
            }
        }
    }

    private func failPendingTurn(_ turn: ChatTurn, _ error: Error) {
        guard turn.status == .running else { return }
        if pendingTurn === turn { pendingTurn = nil }
        turn.status = .failed
        turn.errorMessage = error.localizedDescription
        turn.completedAt = Date()
        persistTurn(turn)
        startNextQueued()
    }

    func interrupt() {
        queued.removeAll()
        // Not handed to the agent yet: `startTurn` sees it's over and
        // doesn't send it.
        if let turn = pendingTurn { finish(turn, outcome: .interrupted) }
        guard let agent else {
            if let turn = activeTurn { finish(turn, outcome: .interrupted) }
            return
        }
        Task { await agent.interrupt() }
    }

    // MARK: - Requests

    func respond(to request: AgentRequest, with decision: AgentApprovalDecision) {
        requests.removeAll { $0.id == request.id }
        Task { await agent?.respond(to: request.id, with: decision) }
    }

    func answer(_ request: AgentRequest, answers: [String: [String]]) {
        requests.removeAll { $0.id == request.id }
        Task { await agent?.answer(request.id, answers: answers) }
    }

    func resolvePlan(_ request: AgentRequest, with decision: AgentPlanDecision) {
        requests.removeAll { $0.id == request.id }
        if case let .implement(mode) = decision {
            runtimeMode = mode
            interactionMode = .normal
            persistThread()
        }
        Task { [weak self] in
            guard let self, let followUp = await self.agent?.resolvePlan(request.id, with: decision) else { return }
            // The provider ended the plan turn already; continue in a new
            // one, through the normal path so it gets its checkpoint.
            self.interactionMode = followUp.interactionMode
            self.startTurn(text: followUp.text, images: followUp.images)
        }
    }

    // MARK: - Settings

    func setRuntimeMode(_ mode: AgentRuntimeMode) {
        runtimeMode = mode
        persistThread()
        Task {
            do { try await agent?.setRuntimeMode(mode) } catch { banner = error.localizedDescription }
        }
    }

    func setInteractionMode(_ mode: AgentInteractionMode) {
        interactionMode = mode
        persistThread()
    }

    func setModel(_ model: String?, effort: String?) {
        let changedModel = model != self.model
        self.model = model
        self.effort = effort
        persistThread()
        guard changedModel, capabilities?.liveModelSwitch == true else { return }
        Task {
            do { try await agent?.setModel(model) } catch { banner = error.localizedDescription }
        }
    }

    // MARK: - Remote Control

    func setRemoteControl(_ enabled: Bool) {
        if enabled {
            if case .on = remoteControl { return }
            if remoteControl == .starting { return }
            remoteControl = .starting
        } else {
            remoteControl = .off
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureConnected()
                let url = try await self.agent?.setRemoteControl(enabled, name: enabled ? self.title : nil)
                // Turned off again while starting.
                guard enabled, self.remoteControl == .starting else { return }
                self.remoteControl = .on(url)
            } catch {
                guard enabled else { return }
                self.remoteControl = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Revert

    /// Put the worktree back to before `turn` and drop it (and everything
    /// after) from the conversation. Returns the turn's message, for the
    /// composer, so it can be edited and resent — nil when nothing was
    /// reverted (`banner` says why).
    func revert(to turn: ChatTurn) async -> (text: String, images: [String])? {
        guard !isReverting, turns.contains(where: { $0 === turn }) else { return nil }
        isReverting = true
        banner = nil
        // Nothing queued may start while the turns it follows are dropped.
        queued.removeAll()
        defer { isReverting = false }
        if isWorking {
            interrupt()
            // Files are only restored once the agent has stopped
            // writing them.
            guard await waitUntilIdle(timeout: .seconds(15)) else {
                banner = "The running turn didn't stop, so nothing was reverted."
                return nil
            }
        }
        guard let before = turn.checkpointBefore else {
            banner = "This turn has no file snapshot, so it can't be reverted."
            return nil
        }
        // Conversation first: it's the step that can refuse (a turn
        // the provider no longer knows). Files only change once it has
        // succeeded, so the two never drift apart.
        // The first turn from here the provider knows: an earlier one
        // may never have reached it (failed at start).
        let providerTurnId = turns.drop { $0 !== turn }.lazy.compactMap(\.providerTurnId).first
        do {
            if let providerTurnId {
                try await ensureConnected()
                try await agent?.revert(toBefore: providerTurnId)
            }
        } catch {
            banner = "Couldn't revert the conversation: \(error.localizedDescription)"
            return nil
        }
        do {
            try await Checkpointer.restore(worktree: cwd, to: before)
        } catch {
            banner = "The conversation was reverted, but restoring files failed: \(error.localizedDescription)"
        }
        guard let index = turns.firstIndex(where: { $0 === turn }) else { return nil }
        let removed = turns[index...]
        for turn in removed {
            for box in turn.items { boxesByItemId.removeValue(forKey: box.item.id) }
            if let providerId = turn.providerTurnId { turnsByProviderId.removeValue(forKey: providerId) }
        }
        let draft = turn.userMessage.map { ($0.text, $0.images) }
        turns.removeSubrange(index...)
        requests.removeAll()
        todos = []
        ChatStore.truncate(threadId: id, fromSeq: turn.seq)
        persistThread()
        onTurnFinished?(self)
        return draft ?? ("", [])
    }

    private func waitUntilIdle(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isWorking, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !isWorking
    }

    // MARK: - Lifecycle

    /// App quitting: stop the process and wait for it.
    func shutdown() async {
        guard let agent = detachAgent() else { return }
        await agent.stop()
    }

    /// Workspace torn down: stop the process. The chat stays in the
    /// database; this object is done with.
    func retire() {
        disconnect()
        isRetired = true
    }

    /// Tab closed: stop the process and mark the thread closed.
    func close() {
        retire()
        // Nothing was said: not worth reopening.
        if turns.contains(where: { $0.userMessage != nil }) {
            ChatStore.setClosed(id, closed: true)
        } else {
            ChatStore.deleteThread(id)
        }
    }

    /// Whether `turn` is still part of this live chat: work finishing after
    /// a revert or close must not write it back.
    private func isLive(_ turn: ChatTurn) -> Bool {
        !isRetired && turns.contains { $0 === turn }
    }

    // MARK: - Event reduction

    private func handle(_ event: AgentEvent) {
        if case let .delta(itemId, turnId, kind, text) = event {
            // Join a run of chunks for one field, so the flush grows the
            // item's text once rather than copying it per chunk.
            if let last = pendingDeltas.indices.last,
               pendingDeltas[last].itemId == itemId, pendingDeltas[last].kind == kind {
                pendingDeltas[last].text += text
            } else {
                pendingDeltas.append((itemId, turnId, kind, text))
            }
            scheduleDeltaFlush()
            return
        }
        flushDeltas()

        switch event {
        case let .ready(info):
            connection = .connected
            resume = info.resume
            models = info.models
            commands = info.commands
            if let model = info.model { resolvedModel = model }
            persistThread()

        case let .turnStarted(providerId):
            _ = turn(forProviderId: providerId, create: true)

        case let .item(item):
            upsert(item)

        case .delta:
            break

        case let .requestOpened(request):
            if !requests.contains(where: { $0.id == request.id }) {
                requests.append(request)
                onAttention?(self)
            }

        case let .requestClosed(id):
            requests.removeAll { $0.id == id }

        case let .todos(todos):
            self.todos = todos
            persistThread()

        case let .usage(usage):
            self.usage = usage

        case let .rateLimits(windows):
            rateLimits.merge(windows, for: provider)

        case let .runtimeModeChanged(mode):
            if runtimeMode != mode {
                runtimeMode = mode
                persistThread()
            }

        case let .interactionModeChanged(mode):
            if interactionMode != mode {
                interactionMode = mode
                persistThread()
            }

        case let .modelChanged(model):
            resolvedModel = model

        case let .resumeUpdated(cursor):
            resume = cursor
            persistThread()

        case let .remoteControl(status):
            switch status {
            case let .restarted(url): remoteControl = .on(url)
            case let .failed(message): remoteControl = .failed(message)
            }

        case let .turnCompleted(providerId, outcome):
            if let turn = turn(forProviderId: providerId, create: false) {
                finish(turn, outcome: outcome)
            }

        case let .exited(exit):
            let message = exit.stderr.nonBlank.map { Self.lastLines($0, count: 6) } ?? "exit status \(exit.status)"
            agentEnded(failure: exit.expected ? nil : message)
        }
    }

    /// The local turn for a provider turn id. A new provider turn adopts
    /// the optimistic turn created on send, if there is one.
    private func turn(forProviderId providerId: String, create: Bool) -> ChatTurn? {
        if let existing = turnsByProviderId[providerId] { return existing }
        guard create else { return nil }
        let turn: ChatTurn
        if let pending = pendingTurn ?? sendingTurn {
            turn = pending
            pendingTurn = nil
            sendingTurn = nil
        } else {
            // Started by the provider itself (Codex implementing a plan).
            turn = ChatTurn(id: UUID().uuidString.lowercased(), seq: (turns.last?.seq ?? 0) + 1, status: .running)
            turns.append(turn)
            let seq = turn.seq
            Task { [weak self] in
                guard let self, self.isLive(turn) else { return }
                turn.checkpointBefore = await Checkpointer.capture(
                    worktree: self.cwd, ref: Checkpointer.ref(thread: self.id, turn: String(seq), phase: "before")
                )
                self.persistTurn(turn)
            }
        }
        turn.providerTurnId = providerId
        turnsByProviderId[providerId] = turn
        persistTurn(turn)
        return turn
    }

    private func upsert(_ item: AgentItem) {
        if let box = boxesByItemId[item.id] {
            box.item = item
            if item.status.isTerminal, let turn = owningTurn(of: box) { persistItem(box, in: turn) }
            return
        }
        guard let turn = targetTurn(for: item) else { return }
        // The provider's echo of the message we showed optimistically.
        if case .userMessage = item.content,
           let local = turn.items.first(where: { $0.item.id.hasPrefix("local-") }) {
            var adopted = item
            if case let .userMessage(message) = adopted.content, message.text.isEmpty, let original = turn.userMessage {
                adopted.content = .userMessage(original)
            }
            local.item = adopted
            boxesByItemId[item.id] = local
            persistItem(local, in: turn)
            return
        }
        let box = ChatItemBox(id: item.id, item: item)
        boxesByItemId[item.id] = box
        // A subagent's calls go under it, after its earlier ones: parallel
        // subagents interleave, and a background one reports after its
        // turn has moved on.
        let index = item.parentId
            .flatMap { parent in turn.items.lastIndex { $0.item.id == parent || $0.item.parentId == parent } }
            .map { $0 + 1 } ?? turn.items.count
        turn.items.insert(box, at: index)
        // Items after it moved down a place; their saved order with them.
        for later in turn.items[index...] where later.item.status.isTerminal {
            persistItem(later, in: turn)
        }
    }

    private func targetTurn(for item: AgentItem) -> ChatTurn? {
        if let providerId = item.turnId, let turn = turn(forProviderId: providerId, create: true) {
            return turn
        }
        if let active = activeTurn { return active }
        // Not tied to a turn (a startup notice): give it a turn of its own.
        let turn = ChatTurn(id: UUID().uuidString.lowercased(), seq: (turns.last?.seq ?? 0) + 1, status: .completed)
        turn.completedAt = Date()
        turns.append(turn)
        persistTurn(turn)
        return turn
    }

    private func owningTurn(of box: ChatItemBox) -> ChatTurn? {
        turns.last { turn in turn.items.contains { $0 === box } }
    }

    private func finish(_ turn: ChatTurn, outcome: AgentTurnOutcome) {
        guard turn.status == .running else { return }
        if pendingTurn === turn { pendingTurn = nil }
        switch outcome {
        case .completed: turn.status = .completed
        case .interrupted: turn.status = .interrupted
        case let .failed(message):
            turn.status = .failed
            turn.errorMessage = message
        }
        turn.completedAt = Date()
        // Close out anything the provider left open: text that stopped
        // streaming is complete; tools that never reported back didn't run
        // to the end.
        // Background agents, and their calls, carry on past the turn.
        let background = Set(turn.items.compactMap { box -> String? in
            guard box.item.status == .inProgress, case let .subagent(agent) = box.item.content,
                  agent.runsInBackground == true else { return nil }
            return box.item.id
        })
        for box in turn.items where box.item.status == .inProgress
            && !background.contains(box.item.id) && !background.contains(box.item.parentId ?? "") {
            switch box.item.content {
            case .assistantMessage, .reasoning, .plan, .userMessage:
                box.item.status = .completed
            default:
                box.item.status = turn.status == .completed ? .completed : .interrupted
            }
        }
        for box in turn.items { persistItem(box, in: turn) }
        requests.removeAll { $0.turnId == turn.providerTurnId }
        persistTurn(turn)
        persistThread()

        let seq = turn.seq
        let before = turn.checkpointBefore
        Task { [weak self] in
            guard let self, self.isLive(turn) else { return }
            if let after = await Checkpointer.capture(
                worktree: self.cwd, ref: Checkpointer.ref(thread: self.id, turn: String(seq), phase: "after")
            ) {
                turn.checkpointAfter = after
                if let before {
                    turn.stat = await Checkpointer.stat(worktree: self.cwd, from: before, to: after)
                }
                self.persistTurn(turn)
            }
            self.onTurnFinished?(self)
        }

        onAttention?(self)
        startNextQueued()
    }

    /// Stopping clears the queue (`interrupt`), so anything still queued
    /// was meant to follow whatever the last turn's outcome.
    private func startNextQueued() {
        guard !isWorking, !isRetired, let next = queued.first else { return }
        queued.removeFirst()
        startTurn(text: next.text, images: next.images.map { URL(fileURLWithPath: $0) })
    }

    // MARK: - Deltas

    /// Deltas arrive per token; applying each one would re-render the row
    /// (and re-parse its markdown) dozens of times a second. Batch them.
    private func scheduleDeltaFlush() {
        guard deltaFlushTask == nil else { return }
        deltaFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            self?.flushDeltas()
        }
    }

    private func flushDeltas() {
        deltaFlushTask?.cancel()
        deltaFlushTask = nil
        guard !pendingDeltas.isEmpty else { return }
        let batch = pendingDeltas
        pendingDeltas.removeAll(keepingCapacity: true)
        var updated: [String: AgentItem] = [:]
        var order: [String] = []
        for delta in batch {
            var item: AgentItem
            if let pending = updated[delta.itemId] {
                item = pending
            } else if let box = boxesByItemId[delta.itemId] {
                item = box.item
            } else if let placeholder = AgentItem.placeholder(id: delta.itemId, turnId: delta.turnId, kind: delta.kind) {
                item = placeholder
            } else {
                continue
            }
            if updated[delta.itemId] == nil { order.append(delta.itemId) }
            item.append(delta.text, kind: delta.kind)
            updated[delta.itemId] = item
        }
        for id in order {
            guard let item = updated[id] else { continue }
            upsert(item)
        }
    }

    // MARK: - Persistence

    private func persistThread() {
        guard !isRetired else { return }
        let record = ChatThreadRecord(
            id: id,
            workspaceId: workspaceId,
            provider: provider,
            title: title,
            model: model,
            effort: effort,
            runtimeMode: runtimeMode,
            interactionMode: interactionMode,
            resumeCursor: resume.flatMap { try? ChatStore.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) },
            todos: todos.isEmpty ? nil : (try? ChatStore.encoder.encode(todos)).map { String(decoding: $0, as: UTF8.self) },
            createdAt: createdAt,
            updatedAt: Date(),
            closedAt: nil
        )
        ChatStore.save(record)
    }

    private func persistTurn(_ turn: ChatTurn) {
        guard isLive(turn) else { return }
        ChatStore.save(ChatTurnRecord(
            id: turn.id,
            threadId: id,
            seq: turn.seq,
            providerTurnId: turn.providerTurnId,
            status: turn.status.rawValue,
            errorMessage: turn.errorMessage,
            startedAt: turn.startedAt,
            completedAt: turn.completedAt,
            checkpointBefore: turn.checkpointBefore,
            checkpointAfter: turn.checkpointAfter,
            stat: turn.stat.flatMap { try? ChatStore.encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        ))
    }

    private func persistItem(_ box: ChatItemBox, in turn: ChatTurn) {
        guard isLive(turn), let payload = try? ChatStore.encoder.encode(box.item) else { return }
        let seq = turn.seq * 100_000 + (turn.items.firstIndex { $0 === box } ?? turn.items.count)
        ChatStore.save(ChatItemRecord(id: box.id, threadId: id, turnId: turn.id, seq: seq, payload: payload, createdAt: box.createdAt))
    }

    private func loadTranscript() {
        let (turnRecords, itemRecords) = ChatStore.transcript(threadId: id)
        var byTurn: [String: [ChatItemRecord]] = [:]
        for record in itemRecords { byTurn[record.turnId, default: []].append(record) }
        for record in turnRecords {
            let status = ChatTurn.Status(rawValue: record.status) ?? .completed
            let turn = ChatTurn(id: record.id, seq: record.seq, status: status, startedAt: record.startedAt)
            // A turn still "running" in the database was cut off by a
            // quit or crash.
            if status == .running {
                turn.status = .interrupted
            }
            turn.providerTurnId = record.providerTurnId
            turn.errorMessage = record.errorMessage
            turn.completedAt = record.completedAt
            turn.checkpointBefore = record.checkpointBefore
            turn.checkpointAfter = record.checkpointAfter
            turn.stat = record.stat.flatMap { try? ChatStore.decoder.decode(Checkpointer.Stat.self, from: Data($0.utf8)) }
            for itemRecord in byTurn[record.id] ?? [] {
                guard var item = try? ChatStore.decoder.decode(AgentItem.self, from: itemRecord.payload) else { continue }
                if item.status == .inProgress { item.status = .interrupted }
                let box = ChatItemBox(id: itemRecord.id, item: item, createdAt: itemRecord.createdAt)
                turn.items.append(box)
                boxesByItemId[item.id] = box
            }
            if let providerId = record.providerTurnId { turnsByProviderId[providerId] = turn }
            turns.append(turn)
        }
    }

    // MARK: - Helpers

    static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 48 else { return trimmed.isEmpty ? "New chat" : trimmed }
        return String(trimmed.prefix(47)) + "…"
    }

    private static func lastLines(_ text: String, count: Int) -> String {
        text.split(whereSeparator: \.isNewline).suffix(count).joined(separator: "\n")
    }
}
