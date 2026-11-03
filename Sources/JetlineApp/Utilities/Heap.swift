import Foundation
import CJetlineSys

/// glibc's malloc is slow to give freed memory back. A buffer bigger than
/// the mmap threshold is mapped on its own and unmapped when freed, but the
/// threshold climbs to the largest such buffer freed so far, so after the
/// first multi-MB `gh` reply every later one is carved from a heap instead.
/// Each thread that allocates gets one of up to 8-per-core arenas, and a
/// heap only shrinks from its top, so one live object pins everything below
/// it. The daemon frees MBs of subprocess output every poll on dozens of
/// threads; on the devbox that left 13 GB free but still resident. Off
/// glibc (macOS, musl) these are no-ops.
enum Heap {
    /// glibc's default is 8 per core: hundreds on a big host, each holding
    /// its own free memory. A few are plenty for the daemon's contention.
    static let maxArenas: Int32 = 4
    /// `malloc_trim` takes each arena's lock while it walks it; once a
    /// minute keeps that out of the way and the slack to one poll's worth.
    static let trimInterval: DispatchTimeInterval = .seconds(60)

    /// Before any threads start, so they don't spread over extra arenas.
    static func tune() {
        jl_malloc_tune(maxArenas)
    }

    /// Return the free pages in every arena to the kernel.
    static func trim() {
        jl_malloc_trim()
    }

    /// Trims every `trimInterval` while the returned timer lives.
    static func trimPeriodically() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + trimInterval, repeating: trimInterval, leeway: .seconds(5))
        timer.setEventHandler { trim() }
        timer.resume()
        return timer
    }
}
