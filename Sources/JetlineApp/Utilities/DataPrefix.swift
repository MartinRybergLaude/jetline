import Foundation

extension Data {
    /// Drop the first `count` bytes (all of them, if fewer), freeing them.
    /// `removeFirst(_:)` only re-slices: the dropped bytes stay allocated
    /// and later appends grow the same storage, so a buffer trimmed that way
    /// holds everything ever written to it.
    mutating func removePrefix(_ count: Int) {
        removeSubrange(startIndex..<(startIndex + Swift.min(count, self.count)))
    }
}
