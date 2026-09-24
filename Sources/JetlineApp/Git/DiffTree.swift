import Foundation

/// Flattens a diff's file list into file-tree rows for the changes panel:
/// folders first, then files, each sorted by name. Single-child folder
/// chains are compacted into one row (`apps/web/src`), as editors do.
enum DiffTree {
    enum Row: Identifiable, Equatable {
        case folder(path: String, name: String, depth: Int)
        case file(FileDiff, depth: Int)

        var id: String {
            switch self {
            case .folder(let path, _, _): return "dir:" + path
            case .file(let file, _):      return file.id
            }
        }

        var depth: Int {
            switch self {
            case .folder(_, _, let depth), .file(_, let depth): return depth
            }
        }
    }

    /// Rows for `files`, skipping the contents of any folder whose full
    /// path is in `collapsed`.
    static func rows(for files: [FileDiff], collapsed: Set<String> = []) -> [Row] {
        let root = Node()
        for file in files {
            var node = root
            let components = file.path.split(separator: "/").map(String.init)
            for component in components.dropLast() {
                node = node.child(component)
            }
            node.files.append(file)
        }
        var rows: [Row] = []
        flatten(root, prefix: "", depth: 0, collapsed: collapsed, into: &rows)
        return rows
    }

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [FileDiff] = []

        func child(_ name: String) -> Node {
            if let existing = folders[name] { return existing }
            let node = Node()
            folders[name] = node
            return node
        }
    }

    private static func flatten(_ node: Node, prefix: String, depth: Int,
                                collapsed: Set<String>, into rows: inout [Row]) {
        for key in node.folders.keys.sorted(by: nameOrder) {
            var name = key
            var path = prefix + key
            var folder = node.folders[key]!
            while folder.files.isEmpty, folder.folders.count == 1,
                  let (next, child) = folder.folders.first {
                name += "/" + next
                path += "/" + next
                folder = child
            }
            rows.append(.folder(path: path, name: name, depth: depth))
            if !collapsed.contains(path) {
                flatten(folder, prefix: path + "/", depth: depth + 1,
                        collapsed: collapsed, into: &rows)
            }
        }
        let files = node.files.sorted {
            nameOrder(($0.path as NSString).lastPathComponent,
                      ($1.path as NSString).lastPathComponent)
        }
        rows.append(contentsOf: files.map { .file($0, depth: depth) })
    }

    private static func nameOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
