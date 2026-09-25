import AppKit
import Combine
import Observation

/// The inspector's tab switcher, the way Xcode's inspector has it: a native
/// segmented control in the inspector column's top accessory, sitting on the
/// same Liquid Glass row as the window's tab bar.
@MainActor
final class InspectorTabsAccessory: NSSplitViewItemAccessoryViewController {
    private let state: AppState
    private let control = NSSegmentedControl()
    private static let inset: CGFloat = 10
    private var tabs: [InspectorTab] = []
    private var cancellables: Set<AnyCancellable> = []
    private var trackingGeneration = 0

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        // The soft edge keeps the row on the inspector's own background —
        // the default hard edge paints a band behind it.
        if #available(macOS 26.1, *) {
            preferredScrollEdgeEffectStyle = .soft
        }
        // The standard insets drop the control below the window's tab bar;
        // flush with the toolbar's bottom edge it sits on the same line.
        automaticallyAppliesContentInsets = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        control.trackingMode = .selectOne
        // Xcode's inspector tabs: the thumb lifts into a glass lens that
        // follows the pointer while it's held. (macOS 26 draws the plain
        // segmented look.)
        if #available(macOS 27, *) {
            control.role = .tabs
        }
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.target = self
        control.action = #selector(segmentChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.inset),
            control.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.inset),
            control.topAnchor.constraint(equalTo: container.topAnchor),
            control.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.inset)
        ])
        view = container

        state.$inspectorTab
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        state.$inspectorWorkspaceId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &cancellables)
        reload()
    }

    @objc private func segmentChanged() {
        let index = control.selectedSegment
        guard tabs.indices.contains(index) else { return }
        state.inspectorTab = tabs[index]
    }

    /// Rebuilds the segments. Tracks the inspected workspace's PR so the
    /// unresolved-comment count stays current.
    private func reload() {
        // Every reload arms a fresh observation; only the latest one may
        // trigger the next, or observers pile up with each state change.
        trackingGeneration &+= 1
        let generation = trackingGeneration
        let unresolved = withObservationTracking {
            unresolvedCommentCount
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingGeneration == generation else { return }
                self.reload()
            }
        }
        let tabs = InspectorTab.available(in: state)
        if tabs != self.tabs || control.segmentCount != tabs.count {
            self.tabs = tabs
            control.segmentCount = tabs.count
        }
        for (index, tab) in tabs.enumerated() {
            control.setImage(Self.image(for: tab), forSegment: index)
            control.setLabel(tab == .pr && unresolved > 0 ? "\(unresolved)" : "", forSegment: index)
            control.setToolTip(Self.tooltip(for: tab), forSegment: index)
        }
        control.selectedSegment = tabs.firstIndex(of: state.inspectorTab) ?? 0
    }

    /// Unresolved review threads on the inspected workspace's PR. Already
    /// carried by every `PRTracker` poll, so surfacing it costs nothing.
    private var unresolvedCommentCount: Int {
        guard let id = state.inspectorWorkspaceId,
              case let .loaded(pr, _) = state.workspaceState(for: id).pr else { return 0 }
        return pr.unresolvedThreadCount
    }

    private static func tooltip(for tab: InspectorTab) -> String {
        switch tab {
        case .changes: return "Changes"
        case .pr: return "Pull request"
        case .run: return "Run output"
        }
    }

    private static func image(for tab: InspectorTab) -> NSImage? {
        switch tab {
        case .changes:
            return NSImage(systemSymbolName: "plusminus", accessibilityDescription: "Changes")
        case .pr:
            return prImage
        case .run:
            return NSImage(systemSymbolName: "apple.terminal", accessibilityDescription: "Run output")
        }
    }

    private static let prImage: NSImage? = {
        let image = Bundle.jetlineResources.templateImage("PRStateNone")
        image?.size = NSSize(width: 14, height: 14)
        return image
    }()
}
