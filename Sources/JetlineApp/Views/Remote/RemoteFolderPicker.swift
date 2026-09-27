#if os(macOS)
import AppKit
import SwiftUI

/// Picks a repository folder on the engine's machine. NSOpenPanel only
/// browses this Mac, so a remote engine gets this instead: a path field with
/// a browsable listing of the engine's filesystem.
@MainActor
enum RemoteFolderPicker {
    static func pick(connection: EngineConnection) async -> String? {
        let start = connection.hello?.homeDirectory ?? "~"
        return await withCheckedContinuation { continuation in
            let model = RemoteFolderModel(connection: connection, path: start)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Add Repository on \(connection.target.displayName)"
            panel.isReleasedWhenClosed = false
            // Not modal: the listing loads through async engine requests,
            // which a modal run loop would hold up.
            let closer = PanelCloser()
            var finished = false
            let finish: (String?) -> Void = { result in
                guard !finished else { return }
                finished = true
                panel.delegate = nil
                panel.orderOut(nil)
                continuation.resume(returning: result)
                _ = closer
            }
            closer.onClose = { finish(nil) }
            panel.delegate = closer
            panel.contentView = NSHostingView(rootView: RemoteFolderPickerView(model: model, finish: finish))
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            model.load()
        }
    }
}

private final class PanelCloser: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
@Observable
final class RemoteFolderModel {
    let connection: EngineConnection
    var path: String
    var entries: [DirectoryEntry] = []
    var error: String?
    var isLoading = false

    init(connection: EngineConnection, path: String) {
        self.connection = connection
        self.path = path
    }

    func load() {
        let path = self.path
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                entries = try await connection.call(API.ListDirectory(path: path)).filter(\.isDirectory)
                error = nil
            } catch {
                entries = []
                self.error = (error as? WireError)?.message ?? error.localizedDescription
            }
        }
    }

    func open(_ entry: DirectoryEntry) {
        path = entry.path
        load()
    }

    /// Whether `path` is a git repository, judged from its parent's listing
    /// (the engine marks repositories there).
    func isRepository(_ path: String) async -> Bool {
        if let entry = entries.first(where: { $0.path == path }) { return entry.isGitRepo }
        let parent = (path as NSString).deletingLastPathComponent
        guard let listing = try? await connection.call(API.ListDirectory(path: parent)) else { return false }
        return listing.first { $0.path == path || $0.name == (path as NSString).lastPathComponent }?.isGitRepo ?? false
    }

    func up() {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return }
        path = parent
        load()
    }
}

private struct RemoteFolderPickerView: View {
    @Bindable var model: RemoteFolderModel
    let finish: (String?) -> Void
    @State private var selection: String?
    @State private var addError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a git repository on \(model.connection.target.displayName).")
                .font(.headline)
            HStack {
                Button { model.up() } label: { Image(systemName: "arrow.up") }
                    .help("Parent folder")
                TextField("Path", text: $model.path)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.load() }
                    .font(.system(.body, design: .monospaced))
                Button("Go") { model.load() }
            }
            List(selection: $selection) {
                ForEach(model.entries) { entry in
                    HStack {
                        Image(systemName: entry.isGitRepo ? "arrow.triangle.branch" : "folder")
                            .foregroundStyle(entry.isGitRepo ? Color.accentColor : .secondary)
                        Text(entry.name)
                        Spacer()
                        if entry.isGitRepo {
                            Text("git").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry.path)
                }
            }
            // Double-click (or Return) opens a folder; a repository is what
            // Add takes.
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { paths in
                guard let path = paths.first, let entry = model.entries.first(where: { $0.path == path }) else { return }
                selection = nil
                model.open(entry)
            })
            .overlay {
                if model.isLoading {
                    ProgressView()
                } else if let error = model.error {
                    Text(error).foregroundStyle(.secondary).padding()
                } else if model.entries.isEmpty {
                    Text("No folders here").foregroundStyle(.secondary)
                }
            }
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Text(selection ?? model.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    let path = selection ?? model.path
                    Task {
                        if await model.isRepository(path) {
                            finish(path)
                        } else {
                            model.error = nil
                            addError = "\((path as NSString).lastPathComponent) isn't a git repository."
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 380)
    }
}
#endif
