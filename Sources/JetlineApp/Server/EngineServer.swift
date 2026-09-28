import Foundation
import CJetlineSys

/// Serves an `Engine` to any number of clients over `FramedConnection`s:
/// dispatches requests, publishes state changes as events, and streams
/// terminal output to whoever is attached.
///
/// Publishing: the server watches engine state with `ObservationPump`s —
/// one for the app-wide snapshot, four per workspace (diff, PR, PR
/// conversation, runtime status) — and a `ChatPublisher` per chat that
/// somebody subscribed to. Each emits whole values (patches, for chats) as
/// events to every connected client.
@MainActor
final class EngineServer {
    let engine: Engine
    let engineVersion: String

    private final class Client {
        let id: Int
        let connection: FramedConnection
        /// Said hello: requests are accepted (they may be pipelined behind
        /// it).
        var greeted = false
        /// Has its snapshot: events flow.
        var ready = false
        var chats: Set<String> = []
        var terminals: Set<String> = []
        /// Called `ports.watch`: gets `.ports` events.
        var watchesPorts = false
        /// Its forwarded connections.
        let tunnels: TunnelMux
        init(id: Int, connection: FramedConnection, tunnels: TunnelMux) {
            self.id = id
            self.connection = connection
            self.tunnels = tunnels
        }
    }

    private var clients: [Int: Client] = [:]
    private var nextClientId = 1
    private let encoder = Wire.makeEncoder()
    private let decoder = Wire.makeDecoder()

    private typealias Handler = @MainActor (_ params: Data, _ client: Int) async throws -> Data
    private var handlers: [String: Handler] = [:]

    private var globalPump: ObservationPump<GlobalSnapshot>?
    private var workspacePumps: [String: [any Pump]] = [:]
    private var chatPublishers: [String: ChatPublisher] = [:]
    private let terminals = TerminalHub()
    /// Runs while some client watches ports.
    private let portScanner = PortScanner()

    /// Fires when the last client goes away (the daemon logs it).
    var onClientCountChanged: ((Int) -> Void)?

    /// Opens a forwarded connection's far end: a port on this machine →
    /// a connected socket. Tests swap in their own.
    typealias TunnelConnect = @Sendable (_ port: Int) -> Int32?
    private let tunnelConnect: TunnelConnect?

    init(engine: Engine, engineVersion: String, tunnelConnect: TunnelConnect? = nil) {
        self.engine = engine
        self.engineVersion = engineVersion
        self.tunnelConnect = tunnelConnect
        registerHandlers()
        engine.onWorkspaceStateCreated = { [weak self] ws in self?.publish(workspace: ws) }
        engine.onWorkspaceStateRemoved = { [weak self] id in self?.unpublish(workspaceId: id) }
        engine.onAttention = { [weak self] chat, critical in
            self?.broadcast(.attention(chatId: chat.id, workspaceId: chat.workspaceId, critical: critical))
        }
        engine.onError = { [weak self] message in self?.broadcast(.error(message)) }
        engine.activityLog.onRecord = { [weak self] event in self?.broadcast(.activity(event)) }
        engine.load()
        let pump = ObservationPump<GlobalSnapshot>(read: { [weak engine] in
            engine?.globalSnapshot ?? GlobalSnapshot(
                repositories: [], workspacesByRepo: [:], settings: AppSettings(),
                repoMetadataByRepo: [:], prTrackerStatus: .ok, rateLimits: [:]
            )
        }, emit: { [weak self] snapshot in self?.broadcast(.global(snapshot)) })
        pump.start()
        globalPump = pump
        portScanner.onChange = { [weak self] ports in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.send(.ports(ports), to: self.clients.values.filter(\.watchesPorts).map(\.id))
                }
            }
        }
        for ws in engine.allWorkspaceStates { publish(workspace: ws) }
    }

    var clientCount: Int { clients.count }

    // MARK: - Connections

    /// Take over a connection. The client must `hello` first.
    @discardableResult
    func accept(_ connection: FramedConnection) -> Int {
        let id = nextClientId
        nextClientId += 1
        let scanner = portScanner
        let tunnels = TunnelMux(label: "server-\(id)", connect: tunnelConnect ?? { port in
            // Only ever this machine's own listeners.
            for address in scanner.connectTargets(for: port) {
                let fd = jl_tcp_connect(address, Int32(port), 3000)
                if fd >= 0 { return fd }
            }
            return nil
        }, send: { [weak connection] kind, payload in connection?.send(kind, payload) })
        let client = Client(id: id, connection: connection, tunnels: tunnels)
        clients[id] = client
        let hub = terminals
        connection.onDrained = { [weak hub] in hub?.catchUp(client: id) }
        connection.onFrames = { [weak self] frames in
            // Forwarded bytes skip the main actor.
            var rest: [FramedConnection.Frame] = []
            for frame in frames {
                if frame.kind.isTunnel {
                    tunnels.receive(frame.kind, frame.payload)
                } else {
                    rest.append(frame)
                }
            }
            guard !rest.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.receive(rest, from: id) }
            }
        }
        connection.onClose = { [weak self] in
            tunnels.close()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.disconnect(id) }
            }
        }
        connection.start()
        onClientCountChanged?(clients.count)
        return id
    }

    private func disconnect(_ id: Int) {
        guard let client = clients.removeValue(forKey: id) else { return }
        terminals.removeClient(id)
        if client.watchesPorts, !clients.values.contains(where: \.watchesPorts) { portScanner.stop() }
        for chatId in client.chats { releaseChat(chatId) }
        engine.setFocus(client: id, workspaceId: nil)
        onClientCountChanged?(clients.count)
    }

    private func receive(_ frames: [FramedConnection.Frame], from id: Int) {
        for frame in frames {
            switch frame.kind {
            case .message:
                handleRequest(frame.payload, from: id)
            case .terminalInput:
                guard let (terminalId, bytes) = TerminalFrame.parseInput(frame.payload) else { continue }
                engine.terminal(id: terminalId)?.write(bytes)
            case .terminalOutput, .tunnelOpen, .tunnelData, .tunnelClose, .tunnelAck:
                continue
            }
        }
    }

    private func handleRequest(_ payload: Data, from clientId: Int) {
        guard let head = try? decoder.decode(Wire.RequestHead.self, from: payload) else {
            // Unparseable: answer if there's an id to answer to.
            if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
               let id = (object["id"] as? NSNumber)?.uint64Value {
                respondError(id, WireError("Malformed request.", code: "badRequest"), to: clientId)
            }
            return
        }
        guard let handler = handlers[head.method] else {
            respondError(head.id, WireError("Unknown method \(head.method). The engine may be older than this app.", code: "unknownMethod"), to: clientId)
            return
        }
        if head.method == API.Hello.method {
            clients[clientId]?.greeted = true
        } else if clients[clientId]?.greeted != true {
            respondError(head.id, WireError("hello first", code: "notReady"), to: clientId)
            return
        }
        Task { @MainActor in
            do {
                let result = try await handler(payload, clientId)
                clients[clientId]?.connection.send(.message, result)
            } catch {
                let wire = (error as? WireError) ?? WireError(error.localizedDescription)
                respondError(head.id, wire, to: clientId)
            }
        }
    }

    private func respondError(_ id: UInt64, _ error: WireError, to clientId: Int) {
        let response = Wire.Response<Empty>(id: id, result: nil, error: error)
        guard let data = try? encoder.encode(response) else { return }
        clients[clientId]?.connection.send(.message, data)
    }

    private func on<R: RPC>(_ type: R.Type, _ body: @escaping @MainActor (R, Int) async throws -> R.Response) {
        handlers[R.method] = { [unowned self] payload, clientId in
            let request = try self.decoder.decode(Wire.RequestBody<R>.self, from: payload).params
            let head = try self.decoder.decode(Wire.RequestHead.self, from: payload)
            let result = try await body(request, clientId)
            return try self.encoder.encode(Wire.Response(id: head.id, result: result, error: nil))
        }
    }

    // MARK: - Events

    private func broadcast(_ event: EngineEvent) {
        guard !clients.isEmpty, let data = try? encoder.encode(Wire.Event(event: event)) else { return }
        for client in clients.values where client.ready {
            deliver(data, to: client)
        }
    }

    private func send(_ event: EngineEvent, to clientIds: some Sequence<Int>) {
        guard let data = try? encoder.encode(Wire.Event(event: event)) else { return }
        for id in clientIds {
            guard let client = clients[id], client.ready else { continue }
            deliver(data, to: client)
        }
    }

    /// A client this far behind (a laptop asleep on a half-dead ssh link)
    /// is dropped rather than buffered for without limit; it resyncs with
    /// a fresh hello when it comes back.
    private static let maxClientBacklog = 64 * 1024 * 1024

    private func deliver(_ data: Data, to client: Client) {
        guard client.connection.pendingWriteBytes < Self.maxClientBacklog else {
            client.connection.close()
            return
        }
        client.connection.send(.message, data)
    }

    private func publish(workspace ws: EngineWorkspace) {
        guard workspacePumps[ws.id] == nil else { return }
        let id = ws.id
        let diff = ObservationPump(read: { [weak ws] in
            ws?.diffState ?? WorkspaceDiffState(diff: nil, localDiff: nil, hasUncommitted: false)
        }, emit: { [weak self] value in self?.broadcast(.workspaceDiff(id: id, value)) })
        let pr = ObservationPump(read: { [weak ws] in ws?.pr ?? .loading },
                                 emit: { [weak self] value in self?.broadcast(.workspacePR(id: id, value)) })
        let conversation = ObservationPump(read: { [weak ws] in ws?.conversation ?? .idle },
                                           emit: { [weak self] value in self?.broadcast(.workspaceConversation(id: id, value)) })
        let status = ObservationPump(read: { [weak ws] in
            ws?.status ?? WorkspaceStatus(
                branchPosition: BranchPosition(), runningGitAction: nil, isTogglingAutoMerge: false,
                isRefreshingPR: false, terminals: [], chats: [], setup: nil, run: nil, isOpen: false
            )
        }, emit: { [weak self] value in
            self?.broadcast(.workspaceStatus(id: id, value))
            self?.reconcileTerminalSinks(in: id)
            self?.dropClosedChatPublishers()
        })
        let pumps: [any Pump] = [diff, pr, conversation, status]
        for pump in pumps { pump.start() }
        workspacePumps[id] = pumps
        reconcileTerminalSinks(in: id)
        // Tell existing clients about a workspace that appeared after their
        // hello.
        broadcast(.workspaceStatus(id: id, ws.status))
        broadcast(.workspacePR(id: id, ws.pr))
    }

    private func unpublish(workspaceId id: String) {
        guard let pumps = workspacePumps.removeValue(forKey: id) else { return }
        for pump in pumps { pump.stop() }
        broadcast(.workspaceRemoved(id: id))
        dropClosedChatPublishers()
    }

    private func flushPumps() {
        globalPump?.flush()
        for pumps in workspacePumps.values {
            for pump in pumps { pump.flush() }
        }
    }

    // MARK: - Terminals

    /// Point every terminal of the workspace (tabs, run, setup) at the hub.
    /// Idempotent; called whenever the workspace's status changes, which
    /// covers terminals being created.
    private func reconcileTerminalSinks(in workspaceId: String) {
        let ws = engine.workspaceState(for: workspaceId)
        var all = ws.terminals
        if let t = ws.run?.terminal { all.append(t) }
        if let t = ws.setup?.terminal { all.append(t) }
        for terminal in all { terminals.install(on: terminal) }
        // Drop what closed terminals retained (up to 4 MB each).
        var live = Set<String>()
        for ws in engine.allWorkspaceStates {
            for t in ws.terminals { live.insert(t.id) }
            if let t = ws.run?.terminal { live.insert(t.id) }
            if let t = ws.setup?.terminal { live.insert(t.id) }
        }
        terminals.prune(keeping: live)
    }

    private func attach(terminalId: String, fromOffset: UInt64?, client clientId: Int) throws -> API.AttachResult {
        guard let terminal = engine.terminal(id: terminalId) else {
            throw WireError("That terminal is gone.", code: "noTerminal")
        }
        guard let client = clients[clientId] else { throw WireError.disconnected }
        terminals.install(on: terminal)
        let (start, replayFrom) = terminals.attach(
            terminalId: terminalId,
            buffer: terminal.buffer,
            fromOffset: fromOffset,
            client: clientId,
            connection: client.connection
        )
        client.terminals.insert(terminalId)
        if terminal.buffer.range.end > 0 {
            // The client's resize (sent with the attach) lands first.
            Task { @MainActor [weak terminal] in
                try? await Task.sleep(for: .milliseconds(150))
                terminal?.redraw()
            }
        }
        return API.AttachResult(bufferStart: start, replayFrom: replayFrom, info: terminal.info)
    }

    // MARK: - Chats

    private func subscribe(chatId: String, client clientId: Int) throws -> ChatPatch {
        guard let chat = engine.chat(id: chatId) else {
            throw WireError("That chat is closed.", code: "noChat")
        }
        let publisher: ChatPublisher
        if let existing = chatPublishers[chatId] {
            publisher = existing
        } else {
            publisher = ChatPublisher(chat: chat) { [weak self] patch in
                guard let self else { return }
                let subscribers = self.clients.values.filter { $0.chats.contains(chatId) }.map(\.id)
                self.send(.chat(id: chatId, patch), to: subscribers)
            }
            publisher.start()
            chatPublishers[chatId] = publisher
        }
        // The full patch flushes pending changes to existing subscribers
        // first, so they stay consistent with the new baseline.
        let full = publisher.fullPatch()
        clients[clientId]?.chats.insert(chatId)
        return full
    }

    private func releaseChat(_ chatId: String) {
        let stillWanted = clients.values.contains { $0.chats.contains(chatId) }
        guard !stillWanted, let publisher = chatPublishers.removeValue(forKey: chatId) else { return }
        publisher.stop()
    }

    private func dropClosedChatPublishers() {
        for (chatId, publisher) in chatPublishers where engine.chat(id: chatId) == nil {
            publisher.stop()
            chatPublishers.removeValue(forKey: chatId)
            for client in clients.values { client.chats.remove(chatId) }
        }
    }

    // MARK: - Helpers

    private func workspace(_ id: String) throws -> Workspace {
        guard let ws = engine.workspaceById(id) else {
            throw WireError("That workspace no longer exists.", code: "noWorkspace")
        }
        return ws
    }

    private func repository(_ id: String) throws -> Repository {
        guard let repo = engine.repository(id: id) else {
            throw WireError("That repository is no longer in Jetline.", code: "noRepository")
        }
        return repo
    }

    private func chat(_ id: String) throws -> ChatEngine {
        guard let chat = engine.chat(id: id) else {
            throw WireError("That chat is closed.", code: "noChat")
        }
        return chat
    }

    private func snapshot() -> EngineSnapshot {
        flushPumps()
        var diffs: [String: WorkspaceDiffState] = [:]
        var prs: [String: PRSnapshot] = [:]
        var conversations: [String: PRConversationSnapshot] = [:]
        var statuses: [String: WorkspaceStatus] = [:]
        for ws in engine.allWorkspaceStates {
            if ws.diff != nil || ws.localDiff != nil { diffs[ws.id] = ws.diffState }
            prs[ws.id] = ws.pr
            if ws.conversation != .idle { conversations[ws.id] = ws.conversation }
            statuses[ws.id] = ws.status
        }
        return EngineSnapshot(
            global: engine.globalSnapshot,
            diffs: diffs,
            prs: prs,
            conversations: conversations,
            statuses: statuses,
            activity: Array(engine.activityLog.events.suffix(300))
        )
    }

    // MARK: - Handlers

    private func registerHandlers() {
        let engine = self.engine

        on(API.Hello.self) { [unowned self] req, clientId in
            guard req.protocolVersion == Wire.protocolVersion else {
                self.clients[clientId]?.greeted = false
                throw WireError(
                    "This Jetline app speaks protocol \(req.protocolVersion) but the engine speaks \(Wire.protocolVersion). Update the older side.",
                    code: "protocolMismatch"
                )
            }
            let snapshot = self.snapshot()
            self.clients[clientId]?.ready = true
            return API.HelloResult(
                protocolVersion: Wire.protocolVersion,
                engineVersion: self.engineVersion,
                hostName: Platform.hostName,
                platform: Platform.name,
                homeDirectory: Platform.homeDirectory.path,
                dataDirectory: Database.dataDirectory().path,
                snapshot: snapshot,
                features: API.features
            )
        }
        on(API.WatchPorts.self) { [unowned self] _, clientId in
            self.clients[clientId]?.watchesPorts = true
            let scanner = self.portScanner
            // Off the main actor: lsof can take a moment.
            _ = await Task.detached { scanner.scanNow() }.value
            // Unless every watcher left meanwhile (`disconnect` stops it).
            if self.clients.values.contains(where: \.watchesPorts) { scanner.start() }
            // The latest list rather than scanNow's: a newer one may have
            // gone out as an event meanwhile, and this reply mustn't undo it.
            return scanner.current
        }
        on(API.SetFocus.self) { req, clientId in
            engine.setFocus(client: clientId, workspaceId: req.workspaceId)
            return Empty()
        }

        // Repositories
        on(API.AddRepository.self) { req, _ in try await engine.addRepository(path: req.path) }
        on(API.RemoveRepository.self) { req, _ in engine.removeRepository(req.repoId); return Empty() }
        on(API.UpdateRepository.self) { req, _ in try engine.updateRepository(req.repository); return Empty() }
        on(API.ReorderRepositories.self) { req, _ in try engine.reorderRepositories(req.orderedIds); return Empty() }
        on(API.RepoRefs.self) { [unowned self] req, _ in
            let repo = try self.repository(req.repoId)
            async let remotes = WorktreeOps.listRemotes(at: repo.path)
            async let refs = WorktreeOps.listBaseRefs(at: repo.path)
            async let slug = WorktreeOps.usernameSlug(at: repo.path)
            return API.RepoRefsResult(remotes: await remotes, baseRefs: await refs, usernameSlug: await slug)
        }
        on(API.RemoteBranches.self) { [unowned self] req, _ in
            let repo = try self.repository(req.repoId)
            let raw = await WorktreeOps.listRemoteBranches(repoPath: repo.path, remote: repo.remoteOrigin)
            return raw.map { API.RemoteBranch(ref: $0.ref, lastCommitAt: $0.lastCommitAt) }
        }
        on(API.OpenPullRequests.self) { [unowned self] req, _ in
            let repo = try self.repository(req.repoId)
            do {
                guard let identifier = try await GitHubRunner.repoIdentifier(cwd: repo.path) else {
                    return .noGitHubRemote
                }
                let prs = try await GitHubRunner.listOpenPRs(repo: identifier, cwd: repo.path)
                return .loaded(identifier, prs)
            } catch GitHubRunner.Error.ghMissing {
                return .ghMissing
            } catch GitHubRunner.Error.authRequired {
                return .authRequired
            }
        }

        // Workspaces
        on(API.CreateWorkspace.self) { [unowned self] req, _ in
            try await engine.createWorkspace(in: try self.repository(req.repoId), name: req.name, overrideExisting: req.overrideExisting)
        }
        on(API.ImportBranch.self) { [unowned self] req, _ in
            try await engine.importBranch(
                in: try self.repository(req.repoId),
                remoteRef: req.remoteRef,
                pullRequest: req.pullRequest,
                name: req.name,
                overrideExisting: req.overrideExisting
            )
        }
        on(API.DeleteWorkspace.self) { [unowned self] req, _ in
            await engine.deleteWorkspace(try self.workspace(req.workspaceId))
            return Empty()
        }
        on(API.ReorderWorkspaces.self) { req, _ in
            try engine.reorderWorkspaces(in: req.repoId, orderedIds: req.orderedIds)
            return Empty()
        }
        on(API.ActivateWorkspace.self) { req, _ in
            engine.activateWorkspace(req.workspaceId, terminalSize: req.terminalSize)
        }
        on(API.CloseWorkspace.self) { req, _ in engine.closeWorkspace(req.workspaceId); return Empty() }
        on(API.RefreshDiff.self) { [unowned self] req, _ in
            await engine.refreshDiff(for: try self.workspace(req.workspaceId))
            return Empty()
        }
        on(API.FullFileDiff.self) { [unowned self] req, _ in
            let ws = try self.workspace(req.workspaceId)
            return try await DiffComputer.fullFileDiff(
                path: req.path,
                status: req.status,
                worktreePath: ws.worktreePath,
                baseBranch: ws.baseBranch,
                mode: req.mode
            )
        }
        on(API.ListFiles.self) { req, _ in
            let out = (try? await GitRunner.runChecked(["ls-files", "-co", "--exclude-standard"], cwd: req.cwd)) ?? ""
            return out.split(separator: "\n").map(String.init)
        }

        // Git actions
        on(API.StartGitAction.self) { [unowned self] req, _ in
            let ws = try self.workspace(req.workspaceId)
            guard let tab = engine.startGitActionSession(for: ws, action: req.action, terminalSize: req.terminalSize) else {
                throw WireError("No prompt is configured for \(req.action.rawValue).")
            }
            return tab
        }
        on(API.FastPathGitAction.self) { [unowned self] req, _ in
            let ws = try self.workspace(req.workspaceId)
            switch req.action {
            case .rebaseOnMain: return await engine.performRebase(for: ws, terminalSize: req.terminalSize)
            case .pullUpdates: return await engine.performPull(for: ws, terminalSize: req.terminalSize)
            default: return engine.startGitActionSession(for: ws, action: req.action, terminalSize: req.terminalSize)
            }
        }
        on(API.Merge.self) { [unowned self] req, _ in
            try await engine.performMerge(for: try self.workspace(req.workspaceId), method: req.method)
            return Empty()
        }
        on(API.SetAutoMerge.self) { [unowned self] req, _ in
            try await engine.setAutoMerge(for: try self.workspace(req.workspaceId), enabling: req.enabled, method: req.method)
            return Empty()
        }

        // Pull requests
        on(API.RefreshPR.self) { req, _ in engine.requestPRRefresh(workspaceId: req.workspaceId); return Empty() }
        on(API.KickPR.self) { req, _ in
            if let id = req.workspaceId { engine.prTracker.kick(workspaceId: id) }
            if let id = req.repoId { engine.prTracker.kick(repoId: id) }
            return Empty()
        }
        on(API.RefreshConversation.self) { req, _ in
            await engine.conversationStore.refresh(workspaceId: req.workspaceId, force: req.force)
            return Empty()
        }
        on(API.PostComment.self) { req, _ in
            await engine.conversationStore.postComment(workspaceId: req.workspaceId, body: req.body)
        }
        on(API.ReplyToThread.self) { req, _ in
            await engine.conversationStore.reply(workspaceId: req.workspaceId, threadId: req.threadId, body: req.body, refreshAfter: req.refreshAfter)
        }
        on(API.SetThreadResolved.self) { req, _ in
            await engine.conversationStore.setResolved(workspaceId: req.workspaceId, threadId: req.threadId, resolved: req.resolved)
        }

        // Terminals
        on(API.CreateTerminal.self) { [unowned self] req, _ in
            let ws = try self.workspace(req.workspaceId)
            let terminal = engine.startNewTerminal(
                for: ws,
                agent: req.agent,
                launchArgs: req.launchArgs,
                initialPrompt: req.initialPrompt,
                terminalSize: req.size
            )
            self.terminals.install(on: terminal)
            return terminal.info
        }
        on(API.AttachTerminal.self) { [unowned self] req, clientId in
            try self.attach(terminalId: req.terminalId, fromOffset: req.fromOffset, client: clientId)
        }
        on(API.DetachTerminal.self) { [unowned self] req, clientId in
            self.terminals.detach(terminalId: req.terminalId, client: clientId)
            self.clients[clientId]?.terminals.remove(req.terminalId)
            return Empty()
        }
        on(API.ResizeTerminal.self) { req, _ in
            engine.terminal(id: req.terminalId)?.resize(req.size)
            return Empty()
        }
        on(API.InterruptTerminal.self) { req, _ in
            engine.terminal(id: req.terminalId)?.interrupt()
            return Empty()
        }
        on(API.CloseTerminal.self) { req, _ in
            engine.closeTerminal(req.terminalId)
            return Empty()
        }
        on(API.TerminalText.self) { req, _ in
            engine.terminal(id: req.terminalId)?.plainText() ?? ""
        }

        // Run
        on(API.ToggleRun.self) { [unowned self] req, _ in
            engine.toggleRun(for: try self.workspace(req.workspaceId))
            return Empty()
        }

        // Chats
        on(API.StartChat.self) { [unowned self] req, _ in
            let ws = try self.workspace(req.workspaceId)
            return engine.startNewChat(for: ws, provider: req.provider, prompt: req.prompt).summary
        }
        on(API.ReopenChat.self) { [unowned self] req, _ in
            let ws = try self.workspace(req.workspaceId)
            guard let chat = engine.reopenChat(threadId: req.threadId, in: ws) else {
                throw WireError("That chat no longer exists.", code: "noChat")
            }
            return chat.summary
        }
        on(API.CloseChat.self) { req, _ in engine.closeChat(req.chatId); return Empty() }
        on(API.ClosedChats.self) { req, _ in ChatStore.closedThreads(workspaceId: req.workspaceId, limit: req.limit) }
        on(API.SubscribeChat.self) { [unowned self] req, clientId in
            try self.subscribe(chatId: req.chatId, client: clientId)
        }
        on(API.UnsubscribeChat.self) { [unowned self] req, clientId in
            self.clients[clientId]?.chats.remove(req.chatId)
            self.releaseChat(req.chatId)
            return Empty()
        }
        on(API.ChatCommand.self) { [unowned self] req, _ in
            let chat = try self.chat(req.chatId)
            return await Self.run(req.command, on: chat)
        }
        on(API.OpenChatInTerminal.self) { [unowned self] req, _ in
            let chat = try self.chat(req.chatId)
            return engine.openChatInTerminal(chat, terminalSize: req.size)?.info
        }
        on(API.CheckpointDiff.self) { req, _ in
            await Checkpointer.diff(worktree: req.cwd, from: req.from, to: req.to)
        }

        // Settings
        on(API.SaveSettings.self) { req, _ in try engine.saveSettings(req.settings); return Empty() }

        // Files
        on(API.ListDirectory.self) { req, _ in try Self.listDirectory(Engine.expandTilde(req.path)) }
        on(API.ReadFile.self) { req, _ in
            let path = Engine.expandTilde(req.path)
            let maxBytes = max(0, req.maxBytes)
            // Off the main actor: a FIFO or a hung mount mustn't freeze the
            // engine.
            return try await Task.detached {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
                      let handle = FileHandle(forReadingAtPath: path) else { return nil as Data? }
                defer { try? handle.close() }
                return try handle.read(upToCount: maxBytes)
            }.value
        }
        on(API.UploadFile.self) { req, _ in
            let dir = Engine.uploadsDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = req.name.replacingOccurrences(of: "/", with: "_")
            let url = dir.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safeName)")
            try req.data.write(to: url)
            return url.path
        }
    }

    private static func run(_ command: API.ChatCommand.Command, on chat: ChatEngine) async -> API.ChatCommandResult {
        switch command {
        case .connect:
            chat.connectIfNeeded()
        case .disconnect:
            chat.disconnect()
        case let .send(text, images):
            chat.send(text: text, images: images.map { URL(fileURLWithPath: $0) })
        case let .removeQueued(id):
            if let message = chat.queued.first(where: { $0.id == id }) { chat.removeQueued(message) }
        case .interrupt:
            chat.interrupt()
        case let .respond(requestId, decision):
            if let request = chat.requests.first(where: { $0.id == requestId }) { chat.respond(to: request, with: decision) }
        case let .answer(requestId, answers):
            if let request = chat.requests.first(where: { $0.id == requestId }) { chat.answer(request, answers: answers) }
        case let .resolvePlan(requestId, decision):
            if let request = chat.requests.first(where: { $0.id == requestId }) { chat.resolvePlan(request, with: decision) }
        case let .setRuntimeMode(mode):
            chat.setRuntimeMode(mode)
        case let .setInteractionMode(mode):
            chat.setInteractionMode(mode)
        case let .setModel(model, effort):
            chat.setModel(model, effort: effort)
        case let .setRemoteControl(enabled):
            chat.setRemoteControl(enabled)
        case .dismissBanner:
            chat.banner = nil
        case let .revert(turnId):
            guard let turn = chat.turns.first(where: { $0.id == turnId }),
                  let draft = await chat.revert(to: turn) else { return .none }
            return API.ChatCommandResult(draft: draft.text, draftImages: draft.images)
        }
        return .none
    }

    private static func listDirectory(_ path: String) throws -> [DirectoryEntry] {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return children.compactMap { child -> DirectoryEntry? in
            let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let isGitRepo = isDirectory && fm.fileExists(atPath: child.appendingPathComponent(".git").path)
            return DirectoryEntry(name: child.lastPathComponent, path: child.path, isDirectory: isDirectory, isGitRepo: isGitRepo)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Terminal output fan-out, called from PTY io queues. Each subscriber has
/// a cursor (the next offset it should get), so output reaches it in order
/// and without repeats. A client that falls behind (more than `maxBacklog`
/// unsent) is skipped; once it drains, it gets the missed range from the
/// buffer. Only bytes that fell out of the buffer are ever lost, and then
/// the client sees the jump in offsets and resets its screen.
final class TerminalHub: @unchecked Sendable {
    private struct Subscriber {
        let connection: FramedConnection
        var next: UInt64
    }

    private let lock = NSLock()
    private var subscribers: [String: [Int: Subscriber]] = [:]
    private var buffers: [String: TerminalBuffer] = [:]
    private static let maxBacklog = 8 * 1024 * 1024
    private static let chunk = 256 * 1024

    @MainActor
    func install(on terminal: EngineTerminal) {
        let id = terminal.id
        let buffer = terminal.buffer
        let fresh: Bool = lock.withLock {
            guard buffers[id] == nil else { return false }
            buffers[id] = buffer
            return true
        }
        guard fresh else { return }
        buffer.setSink { [weak self] offset, data in
            self?.broadcast(terminalId: id, offset: offset, count: data.count)
        }
    }

    /// Replay the retained output from `fromOffset` and subscribe.
    func attach(
        terminalId: String,
        buffer: TerminalBuffer,
        fromOffset: UInt64?,
        client: Int,
        connection: FramedConnection
    ) -> (bufferStart: UInt64, replayFrom: UInt64) {
        lock.withLock {
            let range = buffer.range
            let (from, bytes) = buffer.read(from: fromOffset)
            Self.send(bytes, from: from, id: terminalId, on: connection)
            subscribers[terminalId, default: [:]][client] = Subscriber(connection: connection, next: from + UInt64(bytes.count))
            return (range.start, from)
        }
    }

    /// Forget terminals that are gone.
    func prune(keeping live: Set<String>) {
        lock.withLock {
            for id in buffers.keys where !live.contains(id) {
                buffers[id]?.setSink(nil)
                buffers.removeValue(forKey: id)
                subscribers.removeValue(forKey: id)
            }
        }
    }

    func detach(terminalId: String, client: Int) {
        lock.withLock { _ = subscribers[terminalId]?.removeValue(forKey: client) }
    }

    /// Send a client whatever it was skipped for while it was behind.
    func catchUp(client: Int) {
        lock.withLock {
            for (terminalId, var targets) in subscribers {
                guard var sub = targets[client], let buffer = buffers[terminalId],
                      sub.next < buffer.range.end else { continue }
                let (from, bytes) = buffer.read(from: sub.next)
                Self.send(bytes, from: from, id: terminalId, on: sub.connection)
                sub.next = from + UInt64(bytes.count)
                targets[client] = sub
                subscribers[terminalId] = targets
            }
        }
    }

    func removeClient(_ client: Int) {
        lock.withLock {
            for key in subscribers.keys { subscribers[key]?.removeValue(forKey: client) }
        }
    }

    private func broadcast(terminalId: String, offset: UInt64, count: Int) {
        lock.withLock {
            guard var targets = subscribers[terminalId], !targets.isEmpty, let buffer = buffers[terminalId] else { return }
            let end = offset + UInt64(count)
            for (client, var sub) in targets {
                guard sub.next < end, sub.connection.pendingWriteBytes < Self.maxBacklog else { continue }
                // Everything from the cursor on: normally just this chunk,
                // more when the client was skipped while behind.
                let (from, bytes) = buffer.read(from: sub.next)
                Self.send(bytes, from: from, id: terminalId, on: sub.connection)
                sub.next = from + UInt64(bytes.count)
                targets[client] = sub
            }
            subscribers[terminalId] = targets
        }
    }

    private static func send(_ bytes: Data, from: UInt64, id: String, on connection: FramedConnection) {
        guard !bytes.isEmpty else { return }
        var index = bytes.startIndex
        var offset = from
        while index < bytes.endIndex {
            let end = min(index + chunk, bytes.endIndex)
            connection.send(.terminalOutput, TerminalFrame.output(id: id, offset: offset, bytes: bytes.subdata(in: index..<end)))
            offset += UInt64(end - index)
            index = end
        }
    }
}
