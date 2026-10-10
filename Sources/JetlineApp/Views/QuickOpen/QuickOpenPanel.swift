#if os(macOS)
import SwiftUI
import AppKit

/// Borderless, transparent window the ⌘K card floats in, attached to the
/// main window so it moves with it. Clicks on its transparent margin fall
/// through to the window below, which takes key and dismisses it.
final class QuickOpenPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        // Never merged into the main window's tab group.
        tabbingMode = .disallowed
        backgroundColor = .clear
        isOpaque = false
        // The card draws its own shadow; the window's would trace the
        // transparent margin.
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape, when the text field passes it up the responder chain.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Shows and dismisses the ⌘K switcher as `AppState.showingQuickOpen`
/// asks, and opens the picked workspace. Each showing builds a fresh panel,
/// so the query and focus start over.
@MainActor
final class QuickOpenController: NSObject, NSWindowDelegate {
    private let state: AppState
    /// The window to float over, brought forward if it was hidden.
    private let parentWindow: () -> NSWindow?
    private var panel: QuickOpenPanel?
    private var model: QuickOpenModel?
    private var keyMonitor: Any?

    /// Room around the card for its shadow.
    private static let margin: CGFloat = 32
    /// From the top of the main window to the top of the card, clearing
    /// the toolbar and tab bar.
    private static let topInset: CGFloat = 96

    init(state: AppState, parentWindow: @escaping () -> NSWindow?) {
        self.state = state
        self.parentWindow = parentWindow
    }

    func show() {
        guard panel == nil else { return }
        guard let parent = parentWindow() else {
            state.showingQuickOpen = false
            return
        }
        let model = QuickOpenModel(items: state.quickOpenItems())
        let panel = QuickOpenPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.state.showingQuickOpen = false }
        let content = QuickOpenView(model: model) { [weak self] item in self?.open(item) }
            .environmentObject(state)
            .padding(Self.margin)
            .frame(maxHeight: .infinity, alignment: .top)
        let host = NSHostingView(rootView: content)
        // The panel keeps the frame set below; letting the card's height
        // size the window would move its top as results change.
        host.sizingOptions = []
        panel.contentView = host
        panel.setFrame(frame(over: parent), display: false)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        self.model = model
        installKeyMonitor()
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        model = nil
        removeKeyMonitor()
        let parent = panel.parent
        // Clicking another window took key already; don't take it back.
        let hadKey = panel.isKeyWindow
        panel.delegate = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if state.showingQuickOpen { state.showingQuickOpen = false }
        if hadKey { parent?.makeKey() }
    }

    private func open(_ item: QuickOpenItem) {
        dismiss()
        state.selectWorkspace(item.id)
    }

    /// Centered over the main window, its top a fixed distance below the
    /// window's, tall enough for the full list.
    private func frame(over parent: NSWindow) -> NSRect {
        let width = QuickOpenView.width + Self.margin * 2
        let height = QuickOpenView.maxHeight + Self.margin * 2
        let top = parent.frame.maxY - Self.topInset + Self.margin
        return NSRect(x: parent.frame.midX - width / 2, y: top - height, width: width, height: height)
    }

    func windowDidResignKey(_ notification: Notification) {
        state.showingQuickOpen = false
    }

    // MARK: - Keys

    /// The text field keeps typing and Return; arrows (and ⌃N / ⌃P) move
    /// the highlight, Escape closes.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        let control = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control
        let key = control ? event.charactersIgnoringModifiers : nil
        if event.keyCode == KeyCode.down || key == "n" {
            model?.moveHighlight(by: 1)
        } else if event.keyCode == KeyCode.up || key == "p" {
            model?.moveHighlight(by: -1)
        } else if event.keyCode == KeyCode.escape {
            state.showingQuickOpen = false
        } else {
            return false
        }
        return true
    }

    private enum KeyCode {
        static let escape: UInt16 = 53
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }
}
#endif
