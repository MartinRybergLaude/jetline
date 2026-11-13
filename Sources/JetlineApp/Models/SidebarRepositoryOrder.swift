import Foundation

struct SidebarRepositoryEntry: Identifiable, Equatable {
    let hostId: String
    let repository: Repository?
    let isFirstOfHost: Bool

    var id: String { hostId + "|" + (repository?.id ?? "") }
}

struct SidebarRepositoryMove: Equatable {
    let hostId: String
    let offsets: IndexSet
    let destination: Int
}

enum SidebarRepositoryOrder {
    static func entries(
        _ hosts: [(id: String, repositories: [Repository])],
        grouped: Bool
    ) -> [SidebarRepositoryEntry] {
        hosts.flatMap { host -> [SidebarRepositoryEntry] in
            if host.repositories.isEmpty {
                return grouped ? [SidebarRepositoryEntry(hostId: host.id, repository: nil, isFirstOfHost: true)] : []
            }
            return host.repositories.enumerated().map { idx, repo in
                SidebarRepositoryEntry(hostId: host.id, repository: repo, isFirstOfHost: idx == 0)
            }
        }
    }

    static func move(
        in entries: [SidebarRepositoryEntry],
        from offsets: IndexSet,
        to destination: Int
    ) -> SidebarRepositoryMove? {
        guard let first = offsets.first,
              let last = offsets.last,
              last < entries.count,
              destination >= 0,
              destination <= entries.count else { return nil }
        let hostId = entries[first].hostId
        guard offsets.allSatisfy({ entries[$0].hostId == hostId && entries[$0].repository != nil }),
              let start = entries.firstIndex(where: { $0.hostId == hostId }),
              let end = entries.lastIndex(where: { $0.hostId == hostId }).map({ $0 + 1 }),
              (start...end).contains(destination) else { return nil }
        return SidebarRepositoryMove(
            hostId: hostId,
            offsets: IndexSet(offsets.map { $0 - start }),
            destination: destination - start
        )
    }
}
