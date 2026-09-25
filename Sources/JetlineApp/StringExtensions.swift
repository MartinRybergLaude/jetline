import Foundation

extension String {
    /// Returns `self` trimmed of whitespace/newlines, or `nil` if empty.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `self` relative to `root` when it lies inside it, else unchanged.
    func relative(to root: String) -> String {
        hasPrefix(root + "/") ? String(dropFirst(root.count + 1)) : self
    }
}
