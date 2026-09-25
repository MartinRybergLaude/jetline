import Foundation

/// A live connection to one agent conversation. Implementations own the CLI
/// process and translate its protocol into `AgentEvent`s.
///
/// Providers are actors: protocol bookkeeping (request ids, open content
/// blocks, pending approvals) stays off the main thread, and the chat
/// session consumes `events` on the main actor.
protocol AgentProvider: Actor {
    nonisolated var kind: AgentProviderKind { get }
    nonisolated var capabilities: AgentCapabilities { get }
    /// Every event for the lifetime of the provider. Finishes after
    /// `.exited`.
    nonisolated var events: AsyncStream<AgentEvent> { get }

    /// Spawn the process and start or resume the conversation. Emits
    /// `.ready` on success.
    func start(_ config: AgentSessionConfig) async throws

    /// Send a user message. Starts a turn when idle; steers the running one
    /// when the provider supports it.
    func send(_ input: AgentTurnInput) async throws

    /// Stop the running turn. The session stays usable.
    func interrupt() async

    func respond(to requestId: String, with decision: AgentApprovalDecision) async
    func answer(_ requestId: String, answers: [String: [String]]) async
    /// Answer a plan approval. Returns a message the chat should send as
    /// a new turn when the provider can't continue inside the current one
    /// (Codex ends a plan-mode turn before the user decides); the chat
    /// sends it through its normal path so the turn gets a checkpoint.
    func resolvePlan(_ requestId: String, with decision: AgentPlanDecision) async -> AgentTurnInput?

    /// Drop `turnId` and every later turn from the conversation, so the
    /// agent no longer remembers them. Files are restored separately, from
    /// Jetline's own checkpoints.
    func revert(toBefore turnId: String) async throws

    func setRuntimeMode(_ mode: AgentRuntimeMode) async throws
    func setModel(_ model: String?) async throws

    /// Turn Remote Control on (returning the session's claude.ai link) or
    /// off.
    func setRemoteControl(_ enabled: Bool, name: String?) async throws -> URL?

    /// Terminate the process. Emits `.exited` with `expected: true`.
    func stop() async
}
