#if os(macOS)
import SwiftUI
import AppKit

/// The PR panel's SwiftUI-built rows: the summary cards above the
/// conversation and the composer below it.
enum PRHostedRow: Hashable, CaseIterable {
    case header, gates, conversation, composer
}

/// The loaded PR panel as an `NSTableView`. A `LazyVStack` of markdown
/// cards guessed the heights of rows it hadn't built yet and corrected them
/// as they scrolled in, so a fast scroll through a long review made the
/// content and the scroller jump. Here every row is measured exactly, once
/// per width, before it's on screen (see `ChatTimelineView`, which does the
/// same for the chat).
struct PRTimelineView: View {
    let workspaceId: String
    let conversation: PRConversationSnapshot
    let hideResolved: Bool
    let store: PRConversationStore
    let hosted: (PRHostedRow) -> AnyView
    @State private var isAtBottom = true
    @State private var handle = PRTimelineHandle()

    var body: some View {
        PRTimelineRepresentable(
            workspaceId: workspaceId,
            conversation: conversation,
            hideResolved: hideResolved,
            store: store,
            hosted: hosted,
            handle: handle,
            isAtBottom: $isAtBottom
        )
        // As in the chat.
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

/// Lets the SwiftUI button drive the AppKit timeline.
@MainActor
final class PRTimelineHandle {
    weak var controller: PRTimelineController?

    func scrollToBottom() {
        controller?.scrollToBottom()
    }
}

private struct PRTimelineRepresentable: NSViewRepresentable {
    let workspaceId: String
    let conversation: PRConversationSnapshot
    let hideResolved: Bool
    let store: PRConversationStore
    let hosted: (PRHostedRow) -> AnyView
    let handle: PRTimelineHandle
    @Binding var isAtBottom: Bool

    func makeCoordinator() -> PRTimelineController {
        PRTimelineController(workspaceId: workspaceId, store: store)
    }

    func makeNSView(context: Context) -> NSView {
        update(context.coordinator)
        return context.coordinator.scrollView
    }

    func updateNSView(_ view: NSView, context: Context) {
        update(context.coordinator)
    }

    private func update(_ controller: PRTimelineController) {
        handle.controller = controller
        let binding = $isAtBottom
        controller.onBottomChange = { value in
            // Out of the AppKit callback: it can arrive during a SwiftUI
            // update pass.
            DispatchQueue.main.async {
                if binding.wrappedValue != value { binding.wrappedValue = value }
            }
        }
        controller.setHosted(hosted)
        controller.update(conversation: conversation, hideResolved: hideResolved, monoFamily: MonoFont.family)
    }
}

enum PRTimelineRow: Equatable {
    case hosted(PRHostedRow)
    case description(PRComment)
    case item(PRTimelineItem)
    case note(String)

    var id: String {
        switch self {
        case let .hosted(kind):          return "hosted.\(kind)"
        case let .description(comment):  return "description.\(comment.id)"
        case let .item(item):            return item.id
        case let .note(text):            return "note.\(text)"
        }
    }
}

// MARK: - Controller

@MainActor
final class PRTimelineController: NSObject, NSTableViewDataSource, NSTableViewDelegate, PRTimelineHost {
    private struct CachedRoot {
        var row: PRTimelineRow
        var uiVersion: Int
        var monoFamily: String?
        var root: ChatNode
    }

    private struct Anchor {
        var id: String
        var offset: CGFloat
    }

    /// Space above the first row and below the last.
    private static let edge: CGFloat = 8
    /// Space between rows.
    private static let gap: CGFloat = 12
    private static let sidePadding: CGFloat = 12

    let scrollView = PRTimelineScrollView()
    private let tableView = ChatTableView()
    private let workspaceId: String
    private let store: PRConversationStore

    private var rows: [PRTimelineRow] = []
    private var roots: [String: CachedRoot] = [:]
    private var uiVersions: [String: Int] = [:]
    private var flags: [String: Bool] = [:]
    private var threads: [String: PRThreadUIState] = [:]
    private var monoFamily: String?

    private var hostedFactory: ((PRHostedRow) -> AnyView)?
    private var hostedControllers: [PRHostedRow: NSHostingController<AnyView>] = [:]
    private var hostedCells: [PRHostedRow: PRHostedCell] = [:]
    private var hostedHeights: [PRHostedRow: CGFloat] = [:]

    private var width: CGFloat = -1
    private var needsHeightRefresh = false
    private var isAtBottom = true
    private var scrollingToBottom = false
    var onBottomChange: ((Bool) -> Void)?

    init(workspaceId: String, store: PRConversationStore) {
        self.workspaceId = workspaceId
        self.store = store
        super.init()

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pr"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.allowsTypeSelect = false
        tableView.focusRingType = .none
        tableView.refusesFirstResponder = true
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.controller = self

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.frameDidChangeNotification, object: tableView)
    }

    // MARK: Updates

    func setHosted(_ factory: @escaping (PRHostedRow) -> AnyView) {
        hostedFactory = factory
        for (kind, controller) in hostedControllers {
            controller.rootView = wrapped(kind)
        }
    }

    func update(conversation: PRConversationSnapshot, hideResolved: Bool, monoFamily: String?) {
        let fontChanged = monoFamily != self.monoFamily
        self.monoFamily = monoFamily
        let new = Self.rows(conversation: conversation, hideResolved: hideResolved)
        let old = rows
        guard new != old || fontChanged else { return }
        guard width > 0 else {
            rows = new
            return
        }

        preservingPosition {
            let oldIndex = Dictionary(old.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            rows = new
            let oldIds = old.map(\.id)
            let newIds = new.map(\.id)
            if oldIds != newIds {
                var removals = IndexSet()
                var insertions = IndexSet()
                for change in newIds.difference(from: oldIds) {
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
                if fontChanged || oldIndex[row.id].map({ old[$0] != row }) == true { changed.insert(index) }
            }
            // First and last rows carry the edge insets.
            if let first = new.indices.first { changed.insert(first) }
            if let last = new.indices.last { changed.insert(last) }
            for index in changed { refreshCell(at: index) }
            noteHeights(changed)
        }
    }

    private static func rows(conversation: PRConversationSnapshot, hideResolved: Bool) -> [PRTimelineRow] {
        var rows: [PRTimelineRow] = [.hosted(.header), .hosted(.gates), .hosted(.conversation)]
        guard case let .loaded(conversation) = conversation else { return rows }
        if let description = conversation.description {
            rows.append(.description(description))
        }
        let items = hideResolved ? conversation.items.filter { !$0.isResolvedThread } : conversation.items
        rows += items.map { .item($0) }
        if conversation.isEmpty { rows.append(.note("No comments yet.")) }
        if conversation.truncated { rows.append(.note("Only the first 100 comments, reviews and threads are shown.")) }
        rows.append(.hosted(.composer))
        return rows
    }

    /// First layout with a real width, and every width change after it.
    fileprivate func viewDidLayout() {
        let width = scrollView.contentView.bounds.width
        guard width > 0, width != self.width else { return }
        let first = self.width < 0
        self.width = width
        if first {
            measureHosted()
            tableView.reloadData()
            updateAtBottom()
            return
        }
        measureHosted()
        // While the window is being dragged, re-measure only what's on
        // screen; the rest catches up once the drag ends.
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

    private func rowUIChanged(_ id: String) {
        uiVersions[id, default: 0] += 1
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        preservingPosition {
            refreshCell(at: index)
            noteHeights(IndexSet(integer: index))
        }
    }

    // MARK: Rows

    private func insets(at index: Int) -> (top: CGFloat, bottom: CGFloat) {
        (index == 0 ? Self.edge : 0, index == rows.count - 1 ? Self.edge : Self.gap)
    }

    private func root(at index: Int) -> ChatNode {
        let row = rows[index]
        let ui = uiVersions[row.id] ?? 0
        if let cached = roots[row.id], cached.uiVersion == ui, cached.monoFamily == monoFamily, cached.row == row {
            return cached.root
        }
        let content: ChatNode
        switch row {
        case let .description(comment):
            content = PRTimelineNodes.comment(comment, role: .description, row: row.id, host: self)
        case let .item(.comment(comment)):
            content = PRTimelineNodes.comment(comment, role: .comment, row: row.id, host: self)
        case let .item(.review(review)):
            content = PRTimelineNodes.review(review, row: row.id, host: self)
        case let .item(.thread(thread)):
            content = PRTimelineNodes.thread(thread, row: row.id, host: self)
            // The node now carries the request.
            threads[thread.id]?.focusReply = false
        case let .note(text):
            content = PRTimelineNodes.note(text)
        case .hosted:
            content = FillNode()
        }
        let root = BoxNode(content, padding: NSEdgeInsets(h: Self.sidePadding, v: 0))
        roots[row.id] = CachedRoot(row: row, uiVersion: ui, monoFamily: monoFamily, root: root)
        return root
    }

    private func refreshCell(at index: Int) {
        guard index < rows.count else { return }
        let view = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
        let (top, bottom) = insets(at: index)
        if let cell = view as? PRNodeCell {
            cell.show(root(at: index), top: top, bottom: bottom)
        } else if let cell = view as? PRHostedCell {
            cell.setInsets(top: top, bottom: bottom)
        }
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

    // MARK: Hosted rows

    private func wrapped(_ kind: PRHostedRow) -> AnyView {
        let content = hostedFactory?(kind) ?? AnyView(EmptyView())
        return AnyView(
            content
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Self.sidePadding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                    // Out of SwiftUI's update pass.
                    DispatchQueue.main.async { self?.hostedHeightChanged(kind, height) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
        )
    }

    private func hostedController(_ kind: PRHostedRow) -> NSHostingController<AnyView> {
        if let existing = hostedControllers[kind] { return existing }
        let controller = NSHostingController(rootView: wrapped(kind))
        controller.sizingOptions = []
        controller.safeAreaRegions = []
        hostedControllers[kind] = controller
        return controller
    }

    private func hostedCell(_ kind: PRHostedRow) -> PRHostedCell {
        if let existing = hostedCells[kind] { return existing }
        let cell = PRHostedCell(hosting: hostedController(kind).view)
        hostedCells[kind] = cell
        return cell
    }

    private func measureHosted() {
        guard width > 0 else { return }
        for kind in PRHostedRow.allCases where rows.contains(.hosted(kind)) {
            let size = hostedController(kind).sizeThatFits(in: CGSize(width: width, height: 100_000))
            hostedHeights[kind] = ceil(size.height)
        }
    }

    private func hostedHeight(_ kind: PRHostedRow) -> CGFloat {
        if let known = hostedHeights[kind] { return known }
        guard width > 0 else { return 1 }
        let height = ceil(hostedController(kind).sizeThatFits(in: CGSize(width: width, height: 100_000)).height)
        hostedHeights[kind] = height
        return height
    }

    private func hostedHeightChanged(_ kind: PRHostedRow, _ height: CGFloat) {
        let height = ceil(height)
        guard abs((hostedHeights[kind] ?? -1) - height) > 0.5 else { return }
        hostedHeights[kind] = height
        guard let index = rows.firstIndex(of: .hosted(kind)) else { return }
        preservingPosition { noteHeights(IndexSet(integer: index)) }
    }

    // MARK: Scroll position

    /// Keeps the first visible row where it is on screen while heights
    /// change around it.
    private func preservingPosition(_ change: () -> Void) {
        let anchor = captureAnchor()
        change()
        if let anchor { restore(anchor) }
        updateAtBottom()
    }

    func scrollToBottom() {
        tableView.tile()
        let clip = scrollView.contentView
        let y = max(0, tableView.frame.height - clip.bounds.height)
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
        setAtBottom(true)
    }

    private func finishScrollToBottom() {
        scrollingToBottom = false
        scrollView.reflectScrolledClipView(scrollView.contentView)
        updateAtBottom()
    }

    @objc private func boundsChanged(_ note: Notification) {
        guard !scrollingToBottom else { return }
        updateAtBottom()
    }

    private func updateAtBottom() {
        guard width > 0 else { return }
        let clip = scrollView.contentView
        setAtBottom(clip.bounds.maxY >= tableView.frame.height - 40)
    }

    private func setAtBottom(_ value: Bool) {
        guard value != isAtBottom else { return }
        isAtBottom = value
        onBottomChange?(value)
    }

    private func captureAnchor() -> Anchor? {
        let visible = scrollView.contentView.bounds
        guard visible.minY > 0 else { return nil }
        let range = tableView.rows(in: visible)
        guard range.location != NSNotFound, range.length > 0, range.location < rows.count else { return nil }
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

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { width > 0 ? rows.count : 0 }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 1 }
        let (top, bottom) = insets(at: row)
        let content: CGFloat
        if case let .hosted(kind) = rows[row] {
            content = hostedHeight(kind)
        } else {
            content = root(at: row).size(for: width).height
        }
        return max(1, content + top + bottom)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (top, bottom) = insets(at: row)
        if case let .hosted(kind) = rows[row] {
            let cell = hostedCell(kind)
            cell.setInsets(top: top, bottom: bottom)
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("node")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? PRNodeCell ?? {
            let cell = PRNodeCell()
            cell.identifier = identifier
            return cell
        }()
        cell.show(root(at: row), top: top, bottom: bottom)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: PRTimelineHost

    /// Seeds the default on first read, so a thread resolved from here
    /// stays open rather than collapsing when its default flips.
    func isExpanded(_ key: String, default value: Bool) -> Bool {
        if let stored = flags[key] { return stored }
        flags[key] = value
        return value
    }

    func toggle(_ key: String, default value: Bool, row: String) {
        flags[key] = !(flags[key] ?? value)
        rowUIChanged(row)
    }

    func refresh(row: String) {
        rowUIChanged(row)
    }

    func threadState(_ id: String) -> PRThreadUIState {
        threads[id] ?? PRThreadUIState()
    }

    func updateThread(_ id: String, _ change: (inout PRThreadUIState) -> Void) {
        var state = threads[id] ?? PRThreadUIState()
        change(&state)
        guard state != threads[id] else { return }
        threads[id] = state
        rowUIChanged(id)
    }

    /// Typing rebuilds the row only when the reply turns blank or not,
    /// which is all the buttons care about.
    func replyTextChanged(thread id: String, text: String) {
        var state = threads[id] ?? PRThreadUIState()
        let wasBlank = state.replyText.nonBlank == nil
        state.replyText = text
        threads[id] = state
        if wasBlank != (text.nonBlank == nil) { rowUIChanged(id) }
    }

    func threadLayoutChanged(_ id: String) {
        rowUIChanged(id)
    }

    func submitReply(thread: PRReviewThread, thenResolve: Bool) {
        let state = threadState(thread.id)
        guard let body = state.replyText.nonBlank, !state.isSubmitting else { return }
        updateThread(thread.id) { state in
            state.isSubmitting = true
            state.errorMessage = nil
        }
        let store = store
        let workspaceId = workspaceId
        Task { [weak self] in
            var failure = await store.reply(
                workspaceId: workspaceId,
                threadId: thread.id,
                body: body,
                // The resolve's own refresh covers both mutations.
                refreshAfter: !thenResolve
            )
            // The reply is the part that can't be redone from here, so a
            // failed follow-up resolve must not look like a total failure.
            if failure == nil, thenResolve {
                if let resolveFailure = await store.setResolved(workspaceId: workspaceId, threadId: thread.id, resolved: true) {
                    failure = "Reply posted, but resolving failed: \(resolveFailure)"
                }
            }
            self?.updateThread(thread.id) { state in
                state.isSubmitting = false
                if let failure {
                    state.errorMessage = failure
                } else {
                    state.replyText = ""
                    state.isReplying = false
                }
            }
        }
    }

    func setResolved(thread: PRReviewThread, resolved: Bool) {
        guard !threadState(thread.id).isResolving else { return }
        updateThread(thread.id) { state in
            state.isResolving = true
            state.errorMessage = nil
        }
        let store = store
        let workspaceId = workspaceId
        Task { [weak self] in
            let failure = await store.setResolved(workspaceId: workspaceId, threadId: thread.id, resolved: resolved)
            self?.updateThread(thread.id) { state in
                state.isResolving = false
                state.errorMessage = failure
            }
        }
    }
}

// MARK: - Views

final class PRTimelineScrollView: NSScrollView {
    weak var controller: PRTimelineController?

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

/// A node row: mounts its tree below `top` and re-lays it out on resize.
final class PRNodeCell: ChatContainerView {
    private var root: ChatNode?
    private var top: CGFloat = 0
    private var bottom: CGFloat = 0
    private var mountedRoot: ChatNode?
    private var mountedFrame: CGRect = .zero
    private let content = ChatContainerView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(content)
    }

    func show(_ root: ChatNode, top: CGFloat, bottom: CGFloat) {
        self.root = root
        self.top = top
        self.bottom = bottom
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
        let frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - bottom))
        guard root !== mountedRoot || frame != mountedFrame else { return }
        mountedRoot = root
        mountedFrame = frame
        content.frame = frame
        ChatMount.mountChildren(of: root, in: content, size: frame.size, breakout: ChatBreakout())
    }
}

/// Holds one of the SwiftUI rows, which stay alive for the table's life.
final class PRHostedCell: NSView {
    private let hosting: NSView
    private var top: CGFloat = 0
    private var bottom: CGFloat = 0

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        guard top != self.top || bottom != self.bottom else { return }
        self.top = top
        self.bottom = bottom
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hosting.frame = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - bottom))
    }
}
#endif
