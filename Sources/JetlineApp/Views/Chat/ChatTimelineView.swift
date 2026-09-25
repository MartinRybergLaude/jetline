import SwiftUI
import AppKit

/// The scrolling conversation. Follows new output while the user is at the
/// bottom; scrolling up to read stops the follow until they return.
///
/// AppKit underneath: an `NSTableView` recycles row views and knows every
/// row's exact height up front (measured once per width and cached), where
/// a `LazyVStack` rebuilt rows as they scrolled in and guessed heights it
/// then corrected mid-scroll. See `ChatTimelineController`.
struct ChatTimelineView: View {
    let session: ChatSession
    @State private var isAtBottom = true
    @State private var handle = ChatTimelineHandle()

    var body: some View {
        ChatTimelineRepresentable(session: session, fontFamily: FontSettings.shared.chat, monoFamily: MonoFont.family, handle: handle, isAtBottom: $isAtBottom)
            .id(session.id)
            .overlay(alignment: .top) {
                if session.turns.isEmpty {
                    ChatEmptyState(provider: session.provider)
                        .frame(maxWidth: RowRootNode.columnWidth)
                        .padding(.horizontal, RowRootNode.sidePadding)
                        .padding(.top, ChatTimelineModel.topPadding)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        handle.scrollToBottom()
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .padding(16)
                    .help("Scroll to bottom")
                }
            }
    }
}

/// Lets SwiftUI chrome drive the AppKit timeline.
@MainActor
final class ChatTimelineHandle {
    weak var controller: ChatTimelineController?

    func scrollToBottom() {
        controller?.scrollToBottom(animated: true)
    }
}

private struct ChatTimelineRepresentable: NSViewRepresentable {
    let session: ChatSession
    let fontFamily: String?
    let monoFamily: String?
    let handle: ChatTimelineHandle
    @Binding var isAtBottom: Bool

    func makeCoordinator() -> ChatTimelineController {
        ChatTimelineController(session: session)
    }

    func makeNSView(context: Context) -> NSView {
        update(context.coordinator)
        return context.coordinator.scrollView
    }

    func updateNSView(_ view: NSView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ controller: ChatTimelineController) {
        handle.controller = controller
        let binding = $isAtBottom
        controller.onBottomChange = { value in
            // Out of the AppKit callback: it can arrive during a SwiftUI
            // update pass.
            DispatchQueue.main.async {
                if binding.wrappedValue != value { binding.wrappedValue = value }
            }
        }
        controller.setFontFamilies(text: fontFamily, mono: monoFamily)
    }
}

private struct ChatEmptyState: View {
    let provider: AgentProviderKind

    var body: some View {
        VStack(spacing: 10) {
            AgentMark(agent: provider.agentKind, size: 36)
            Text("Chat with \(provider.displayName)")
                .font(.title3.weight(.semibold))
            Text("Ask for a change, a review or an explanation. Type / for commands and @ to mention files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .allowsHitTesting(false)
    }
}

// MARK: - Controller

/// Owns the table. Rows come from `ChatTimelineModel`; each row's content
/// is a node tree (see `ChatNodes`) cached until the row, its UI state or
/// the font changes, so a row is measured once per column width.
@MainActor
final class ChatTimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate, ChatRowHost {
    private struct CachedRoot {
        var row: ChatRow
        var uiVersion: Int
        var styleVersion: Int
        var root: RowRootNode
    }

    private struct Anchor {
        var id: String
        var offset: CGFloat
    }

    let session: ChatSession
    let scrollView: ChatTimelineScrollView
    private let tableView = ChatTableView()
    private let model: ChatTimelineModel
    private var rows: [ChatRow] = []
    private var roots: [String: CachedRoot] = [:]
    private var loaded = false

    private var flags: [String: Bool] = [:]
    private var values: [String: String] = [:]
    private var uiVersions: [String: Int] = [:]
    private var files: [String: [FileDiff]] = [:]
    private var loadingFiles: Set<String> = []

    private(set) var markdownStyle = MarkdownStyle.chat()
    private var fontFamily: String?
    private var monoFamily: String?
    private var styleVersion = 0

    private var columnWidth: CGFloat = -1
    private var needsHeightRefresh = false
    private(set) var isAtBottom = true
    private var scrollingToBottom = false
    var onBottomChange: ((Bool) -> Void)?

    var cwd: String { session.cwd }

    init(session: ChatSession) {
        self.session = session
        model = ChatTimelineModel(session: session)
        scrollView = ChatTimelineScrollView()
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .textBackgroundColor
        tableView.usesAutomaticRowHeights = false
        tableView.allowsTypeSelect = false
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.controller = self

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)

        model.onChange = { [weak self] in self?.reload() }
    }

    // MARK: Updates

    /// First layout with a real width: build every row and start at the
    /// bottom.
    fileprivate func viewDidLayout() {
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        if !loaded {
            loaded = true
            columnWidth = RowRootNode.column(in: width).width
            rows = model.rows()
            tableView.reloadData()
            scrollToBottom(animated: false)
            return
        }
        let column = RowRootNode.column(in: width).width
        guard column != columnWidth else { return }
        columnWidth = column
        // Text rewraps at a new column width. While the window is being
        // dragged, re-measure only what's on screen; the rest catches up
        // once the drag ends.
        if scrollView.inLiveResize {
            needsHeightRefresh = true
            preservingPosition { noteHeights(visibleRows) }
        } else {
            preservingPosition { noteHeights(IndexSet(integersIn: 0..<rows.count)) }
        }
    }

    fileprivate func liveResizeEnded() {
        guard needsHeightRefresh else { return }
        needsHeightRefresh = false
        preservingPosition { noteHeights(IndexSet(integersIn: 0..<rows.count)) }
    }

    func setFontFamilies(text family: String?, mono: String?) {
        guard family != fontFamily || mono != monoFamily || styleVersion == 0 else { return }
        fontFamily = family
        monoFamily = mono
        markdownStyle = .chat(fontFamily: family, monoFamily: mono)
        styleVersion += 1
        guard loaded else { return }
        preservingPosition {
            refreshVisibleCells()
            noteHeights(IndexSet(integersIn: 0..<rows.count))
        }
    }

    private func reload() {
        guard loaded else { return }
        let old = rows
        let new = model.rows()
        guard new != old else { return }
        // A message the user just sent brings them back down to it.
        let sent = new.last(where: { $0.reuseKind == "user" })?.id
        let follows = isAtBottom || (sent != nil && sent != old.last(where: { $0.reuseKind == "user" })?.id)
        let anchor = follows ? nil : captureAnchor()

        let oldIndex = Dictionary(old.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        rows = new
        let oldIds = old.map(\.id)
        let newIds = new.map(\.id)
        if oldIds != newIds {
            let diff = newIds.difference(from: oldIds)
            var removals = IndexSet()
            var insertions = IndexSet()
            for change in diff {
                switch change {
                case let .remove(offset, _, _): removals.insert(offset)
                case let .insert(offset, _, _): insertions.insert(offset)
                }
            }
            tableView.beginUpdates()
            if !removals.isEmpty { tableView.removeRows(at: removals, withAnimation: []) }
            if !insertions.isEmpty { tableView.insertRows(at: insertions, withAnimation: []) }
            tableView.endUpdates()
        }

        var changed = IndexSet()
        for (index, row) in new.enumerated() {
            if let previous = oldIndex[row.id], old[previous] != row { changed.insert(index) }
        }
        if !changed.isEmpty {
            for index in changed { refreshCell(at: index) }
            noteHeights(changed)
        }

        if follows {
            scrollToBottom(animated: false)
        } else if let anchor {
            restore(anchor)
        }
        updateAtBottom()
    }

    /// A row's UI state changed (expanded, a diff loaded): rebuild it where
    /// it stands.
    private func rowUIChanged(_ id: String) {
        uiVersions[id, default: 0] += 1
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        preservingPosition(followBottom: false) {
            refreshCell(at: index)
            noteHeights(IndexSet(integer: index))
        }
        updateAtBottom()
    }

    private func root(for row: ChatRow) -> RowRootNode {
        let ui = uiVersions[row.id] ?? 0
        if let cached = roots[row.id], cached.uiVersion == ui, cached.styleVersion == styleVersion, cached.row == row {
            return cached.root
        }
        let root = ChatRowNodes.root(for: row, host: self)
        roots[row.id] = CachedRoot(row: row, uiVersion: ui, styleVersion: styleVersion, root: root)
        return root
    }

    private func refreshCell(at index: Int) {
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? ChatRowCell else { return }
        cell.show(root(for: rows[index]))
    }

    private func refreshVisibleCells() {
        for index in visibleRows { refreshCell(at: index) }
    }

    private var visibleRows: IndexSet {
        let range = tableView.rows(in: scrollView.contentView.bounds)
        guard range.location != NSNotFound, range.length > 0 else { return [] }
        return IndexSet(integersIn: range.location..<min(rows.count, range.location + range.length))
    }

    private func noteHeights(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            tableView.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    // MARK: Scroll position

    private func preservingPosition(followBottom: Bool = true, _ change: () -> Void) {
        let atBottom = followBottom && isAtBottom
        let anchor = atBottom ? nil : captureAnchor()
        change()
        if atBottom {
            scrollToBottom(animated: false)
        } else if let anchor {
            restore(anchor)
        }
    }

    /// The first visible row and how far into it the viewport starts, so
    /// height changes above the viewport don't move what's on screen.
    private func captureAnchor() -> Anchor? {
        let visible = scrollView.contentView.bounds
        let range = tableView.rows(in: visible)
        guard range.length > 0, range.location < rows.count else { return nil }
        let rect = tableView.rect(ofRow: range.location)
        return Anchor(id: rows[range.location].id, offset: visible.minY - rect.minY)
    }

    private func restore(_ anchor: Anchor) {
        guard let index = rows.firstIndex(where: { $0.id == anchor.id }) else { return }
        tableView.tile()
        let clip = scrollView.contentView
        let maxY = max(0, tableView.frame.height - clip.bounds.height)
        let y = min(max(0, tableView.rect(ofRow: index).minY + anchor.offset), maxY)
        guard abs(clip.bounds.minY - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func scrollToBottom(animated: Bool) {
        tableView.tile()
        let clip = scrollView.contentView
        let y = max(0, tableView.frame.height - clip.bounds.height)
        if animated {
            scrollingToBottom = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishScrollToBottom()
                }
            }
        } else {
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }
        setAtBottom(true)
    }

    private func finishScrollToBottom() {
        scrollingToBottom = false
        let clip = scrollView.contentView
        scrollView.reflectScrolledClipView(clip)
        // Output that arrived during the animation.
        if tableView.frame.height - clip.bounds.maxY > 1 { scrollToBottom(animated: false) }
        setAtBottom(true)
    }

    @objc private func boundsChanged(_ note: Notification) {
        guard !scrollingToBottom else { return }
        updateAtBottom()
    }

    private func updateAtBottom() {
        guard loaded else { return }
        let clip = scrollView.contentView
        setAtBottom(clip.bounds.maxY >= tableView.frame.height - 40)
    }

    private func setAtBottom(_ value: Bool) {
        guard value != isAtBottom else { return }
        isAtBottom = value
        onBottomChange?(value)
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let width = scrollView.contentView.bounds.width
        return max(1, root(for: rows[row]).size(for: width).height)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let data = rows[row]
        let identifier = NSUserInterfaceItemIdentifier(data.reuseKind)
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ChatRowCell ?? {
            let cell = ChatRowCell()
            cell.identifier = identifier
            return cell
        }()
        cell.show(root(for: data))
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: ChatRowHost

    func isExpanded(_ key: String, default value: Bool) -> Bool {
        flags[key] ?? value
    }

    func toggle(_ key: String, default value: Bool, row: String) {
        flags[key] = !(flags[key] ?? value)
        rowUIChanged(row)
    }

    func value(for key: String) -> String? {
        values[key]
    }

    func setValue(_ value: String?, for key: String, row: String) {
        values[key] = value
        rowUIChanged(row)
    }

    func changedFiles(row: String, from: String, to: String) -> [FileDiff]? {
        if let loaded = files[row] { return loaded }
        guard !loadingFiles.contains(row) else { return nil }
        loadingFiles.insert(row)
        let cwd = cwd
        Task { [weak self] in
            let result = await Checkpointer.diff(worktree: cwd, from: from, to: to)
            guard let self else { return }
            files[row] = result
            loadingFiles.remove(row)
            rowUIChanged(row)
        }
        return nil
    }

    func confirmRevert(turn id: String) {
        guard let turn = session.turns.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Revert to before this message?"
        alert.informativeText = "Files are restored to how they were before this message — including changes other tabs made since — and the agent forgets this message and everything after it. The message goes back into the composer."
        let revert = alert.addButton(withTitle: "Revert")
        revert.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let session = session
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { session.revert(to: turn) }
        }
        if let window = scrollView.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

// MARK: - Views

final class ChatTimelineScrollView: NSScrollView {
    weak var controller: ChatTimelineController?

    override func layout() {
        super.layout()
        controller?.viewDidLayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.viewDidLayout()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.liveResizeEnded()
    }
}

final class ChatTableView: NSTableView {
    /// Let text views and controls in rows take clicks and focus.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}

/// One row: mounts its node tree and re-lays it out when the table resizes it.
final class ChatRowCell: ChatContainerView {
    private var root: RowRootNode?
    private var mountedRoot: RowRootNode?
    private var mountedSize: CGSize = .zero

    func show(_ root: RowRootNode) {
        self.root = root
        mountIfNeeded()
    }

    override func layout() {
        super.layout()
        mountIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        mountIfNeeded()
    }

    private func mountIfNeeded() {
        guard let root, bounds.width > 0 else { return }
        guard root !== mountedRoot || bounds.size != mountedSize else { return }
        mountedRoot = root
        mountedSize = bounds.size
        ChatMount.mountChildren(of: root, in: self, size: bounds.size, breakout: ChatBreakout())
    }
}
