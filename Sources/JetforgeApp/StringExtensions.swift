import Foundation

extension String {
    /// Returns `self` trimmed of whitespace/newlines, or `nil` if empty.
    var nonBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
