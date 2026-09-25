/// Replies an agent CLI owes us, by request id. Owned by one provider actor.
struct PendingReplies<Key: Hashable> {
    private var waiting: [Key: CheckedContinuation<JSONValue, Error>] = [:]

    mutating func add(_ key: Key, _ continuation: CheckedContinuation<JSONValue, Error>) {
        waiting[key] = continuation
    }

    /// Resumes `key`'s waiter, if it's still waiting.
    mutating func resolve(_ key: Key, with result: Result<JSONValue, Error>) {
        waiting.removeValue(forKey: key)?.resume(with: result)
    }

    mutating func failAll(_ error: Error) {
        for continuation in waiting.values { continuation.resume(throwing: error) }
        waiting.removeAll()
    }
}
