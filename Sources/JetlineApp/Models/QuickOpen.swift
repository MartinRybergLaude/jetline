import Foundation

/// One row of the ⌘K switcher: a repository's own checkout or one of its
/// workspaces. Opening it selects the workspace, which starts a first tab
/// when none is open.
struct QuickOpenItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// The repository checkout on its default branch.
        case repositoryHead
        case workspace
    }

    /// The workspace id to select.
    let id: String
    let kind: Kind
    let name: String
    let branch: String
    let repositoryName: String
    /// The machine, when repositories from more than one are listed.
    let hostName: String?
    /// Has a terminal or chat tab open.
    let isOpen: Bool
    let lastActiveAt: Date
}

/// Ordering and matching for the ⌘K switcher. Pure, so the ranking can be
/// tested without the panel.
enum QuickOpen {
    /// What an empty query shows: workspaces selected this session, most
    /// recent first, then the rest by last activity. The selected workspace
    /// goes last, since switching to it does nothing.
    static func ordered(_ items: [QuickOpenItem], history: [String], selectedId: String?) -> [QuickOpenItem] {
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let recent = history.reversed().filter { $0 != selectedId }.compactMap { byId[$0] }
        let recentIds = Set(recent.map(\.id))
        let rest = items
            .filter { !recentIds.contains($0.id) && $0.id != selectedId }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        let selected = selectedId.flatMap { byId[$0] }.map { [$0] } ?? []
        return recent + rest + selected
    }

    /// The items matching every whitespace-separated token of `query`
    /// (anywhere in the name, branch, repository or machine), best match
    /// first. Ties, and an empty query, keep the given order.
    static func rank(_ items: [QuickOpenItem], query: String) -> [QuickOpenItem] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.enumerated()
            .compactMap { offset, item in score(item, tokens: tokens).map { (item, $0, offset) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .map(\.0)
    }

    private static func score(_ item: QuickOpenItem, tokens: [String]) -> Int? {
        let fields = [item.name, item.branch, item.repositoryName, item.hostName].compactMap { $0 }
        var total = 0
        for token in tokens {
            guard let best = fields.compactMap({ fuzzyScore(token, in: $0) }).max() else { return nil }
            total += best
        }
        return total
    }

    /// How well `token` matches `text` as an in-order, case-insensitive
    /// subsequence, or `nil` when it doesn't. Contiguous runs and matches
    /// at the start of a word score higher, so "set" ranks "settings" above
    /// "sea eel tank".
    static func fuzzyScore(_ token: String, in text: String) -> Int? {
        let needle = Array(token.lowercased())
        let haystack = Array(text)
        let lowered = haystack.map { Character($0.lowercased()) }
        guard !needle.isEmpty, needle.count <= lowered.count else { return needle.isEmpty ? 0 : nil }

        // Greedy left-to-right can latch onto an early stray letter, so a
        // contiguous occurrence (best at a word start) is scored too.
        let greedy = subsequenceScore(needle, in: lowered, original: haystack)
        let contiguous = contiguousScore(needle, in: lowered, original: haystack)
        switch (greedy, contiguous) {
        case let (g?, c?): return max(g, c)
        case let (g, c): return g ?? c
        }
    }

    private static func subsequenceScore(_ needle: [Character], in lowered: [Character], original: [Character]) -> Int? {
        var matched = 0
        var score = 0
        var previous = -2
        for index in lowered.indices where matched < needle.count && lowered[index] == needle[matched] {
            score += 1
            if index == previous + 1 { score += 4 }
            if isWordStart(index, in: original) { score += 4 }
            previous = index
            matched += 1
        }
        return matched == needle.count ? score : nil
    }

    private static func contiguousScore(_ needle: [Character], in lowered: [Character], original: [Character]) -> Int? {
        let starts = lowered.indices.dropLast(needle.count - 1).filter { start in
            lowered[start..<(start + needle.count)].elementsEqual(needle)
        }
        guard let first = starts.first else { return nil }
        let start = starts.first { isWordStart($0, in: original) } ?? first
        // Scored like the subsequence (every letter but the first follows
        // its neighbour), plus a bonus for the token being one run, so it
        // beats letters scattered over several word starts.
        let run = needle.count + (needle.count - 1) * 4 + needle.count * 2
        return run + (isWordStart(start, in: original) ? 4 : 0)
    }

    /// The text's first letter, one after a separator, or an uppercase
    /// letter after a lowercase one.
    private static func isWordStart(_ index: Int, in text: [Character]) -> Bool {
        guard index > 0 else { return true }
        let previous = text[index - 1]
        if !(previous.isLetter || previous.isNumber) { return true }
        return text[index].isUppercase && previous.isLowercase
    }
}
