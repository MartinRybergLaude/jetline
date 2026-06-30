import Foundation

enum TerminalOutputFilter {
    /// libghostty can wedge when rapid OSC title updates are written through
    /// the host-managed surface path. These chunks only update the terminal
    /// title; Jetline does not rely on them for UI state, so stripping them is
    /// safer than letting them block the main thread.
    static func removingTitleUpdates(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 5 else { return data }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var strippedAny = false

        while index < bytes.count {
            if let endIndex = titleUpdateEndIndex(in: bytes, startingAt: index) {
                strippedAny = true
                index = endIndex
                continue
            }

            output.append(bytes[index])
            index += 1
        }

        guard strippedAny else { return data }
        guard !output.isEmpty else { return nil }
        return Data(output)
    }

    /// Backwards-compatible predicate for tests and callers that only need to
    /// know whether the complete chunk is a title update.
    static func shouldDropStandaloneTitleUpdate(_ data: Data) -> Bool {
        removingTitleUpdates(data) == nil
    }

    private static func titleUpdateEndIndex(in bytes: [UInt8], startingAt index: Int) -> Int? {
        guard index + 4 < bytes.count else { return nil }
        guard bytes[index] == 0x1B, bytes[index + 1] == 0x5D else { return nil } // ESC ]
        guard bytes[index + 2] == 0x30 || bytes[index + 2] == 0x32 else { return nil } // OSC 0 or 2
        guard bytes[index + 3] == 0x3B else { return nil } // ;

        var scan = index + 4
        while scan < bytes.count {
            if bytes[scan] == 0x07 { return scan + 1 } // BEL
            if scan + 1 < bytes.count, bytes[scan] == 0x1B, bytes[scan + 1] == 0x5C {
                return scan + 2 // ST
            }
            scan += 1
        }

        return nil
    }
}
