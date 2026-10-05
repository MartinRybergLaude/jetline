#if os(macOS)
import AppKit
import WebKit

/// Renders mermaid diagrams to vector images.
///
/// Mermaid needs a browser DOM, so one offscreen `WKWebView` does all the
/// rendering, a diagram at a time, and hands back a PDF of the SVG. Views
/// draw the cached image; nothing on screen is a web view. Results are kept
/// per source and appearance (mermaid bakes its theme into the SVG).
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    struct Key: Hashable {
        var source: String
        var dark: Bool
    }

    enum Result {
        /// A PDF-backed image and its natural size in points.
        case diagram(NSImage, CGSize)
        case failed(String)
    }

    private var results: [Key: Result] = [:]
    private var order: [Key] = []
    private static let keep = 120
    /// Per key, one callback per owner: a streaming reply rebuilds its
    /// nodes, and so re-requests, on every chunk.
    private var waiters: [Key: [AnyHashable: () -> Void]] = [:]
    private var queue: [Key] = []
    private var rendering: Key?

    private var webView: WKWebView?
    private var pageURL: URL?
    private var loaded = false
    private var loadGeneration = 0

    func result(_ source: String, dark: Bool) -> Result? {
        results[Key(source: source, dark: dark)]
    }

    /// Either appearance's result. Layout doesn't depend on the theme, so a
    /// diagram can be sized, or known to fail, from whichever came first.
    func anyResult(_ source: String) -> Result? {
        result(source, dark: false) ?? result(source, dark: true)
    }

    /// Renders `source` unless it already has a result, then calls `done`
    /// (once per `owner`). `done` isn't called when the result is already
    /// there.
    func request(_ source: String, dark: Bool, owner: AnyHashable, done: @escaping () -> Void) {
        let key = Key(source: source, dark: dark)
        guard results[key] == nil else { return }
        let pending = waiters[key] != nil
        waiters[key, default: [:]][owner] = done
        guard !pending else { return }
        queue.append(key)
        pump()
    }

    /// The image for `dark`, rendering it if needed and calling `done` when
    /// it lands. Until then, the other appearance's image stands in.
    func image(_ source: String, dark: Bool, owner: AnyHashable, done: @escaping () -> Void) -> NSImage? {
        if case let .diagram(image, _)? = result(source, dark: dark) { return image }
        request(source, dark: dark, owner: owner, done: done)
        if case let .diagram(image, _)? = result(source, dark: !dark) { return image }
        return nil
    }

    private func pump() {
        guard rendering == nil, !queue.isEmpty else { return }
        guard let webView, loaded else {
            loadIfNeeded()
            return
        }
        let key = queue.removeFirst()
        rendering = key
        let generation = loadGeneration
        Task { [weak self] in
            let result = await Self.render(key, in: webView)
            guard let self, generation == self.loadGeneration else { return }
            self.finish(key, result)
        }
    }

    private func finish(_ key: Key, _ result: Result) {
        rendering = nil
        results[key] = result
        order.append(key)
        if order.count > Self.keep {
            let evicted = order.removeFirst()
            results[evicted] = nil
        }
        let callbacks = waiters.removeValue(forKey: key) ?? [:]
        for callback in callbacks.values { callback() }
        pump()
    }

    // MARK: Web view

    private func loadIfNeeded() {
        guard webView == nil else { return }
        guard let page = Bundle.jetlineResources.url(forResource: "mermaid", withExtension: "html") else {
            failAll("Mermaid isn't bundled with this build.")
            return
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Wide enough that diagrams lay out at their natural width; the PDF
        // captures past the viewport anyway.
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        self.webView = webView
        pageURL = page
        // The page loads mermaid.min.js beside it, off the main thread.
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
    }

    private func failAll(_ message: String) {
        let keys = queue
        queue.removeAll()
        for key in keys { finish(key, .failed(message)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        pump()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        // The page itself, and nothing else: a diagram link must not
        // navigate the renderer away.
        decisionHandler(navigationAction.request.url == pageURL ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Start over with a fresh page. The diagram that was rendering is
        // the likely culprit, so it fails rather than retrying.
        loadGeneration += 1
        self.webView = nil
        loaded = false
        if let key = rendering {
            finish(key, .failed("The diagram renderer crashed."))
        } else {
            pump()
        }
    }

    // MARK: Rendering

    private static let renderScript = """
        mermaid.initialize({
            startOnLoad: false,
            theme: dark ? 'dark' : 'default',
            securityLevel: 'strict',
            fontFamily: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif',
        });
        const out = document.getElementById('out');
        out.innerHTML = '';
        try {
            const { svg } = await mermaid.render('jetline-diagram', source);
            out.innerHTML = svg;
            const el = out.querySelector('svg');
            const box = el.viewBox.baseVal;
            const width = Math.ceil(box && box.width ? box.width : el.getBoundingClientRect().width);
            const height = Math.ceil(box && box.height ? box.height : el.getBoundingClientRect().height);
            el.removeAttribute('style');
            el.setAttribute('width', width);
            el.setAttribute('height', height);
            return [width, height];
        } finally {
            // Mermaid leaves its scratch element behind when parsing fails.
            for (const node of Array.from(document.body.children)) {
                if (node !== out) node.remove();
            }
        }
        """

    private static func render(_ key: Key, in webView: WKWebView) async -> Result {
        do {
            let value = try await webView.callAsyncJavaScript(
                renderScript,
                arguments: ["source": key.source, "dark": key.dark],
                contentWorld: .page
            )
            guard let dimensions = value as? [NSNumber], dimensions.count == 2,
                  dimensions[0].doubleValue > 0, dimensions[1].doubleValue > 0 else {
                return .failed("Mermaid produced an empty diagram.")
            }
            let size = CGSize(width: dimensions[0].doubleValue, height: dimensions[1].doubleValue)
            let config = WKPDFConfiguration()
            config.rect = CGRect(origin: .zero, size: size)
            let data = try await webView.pdf(configuration: config)
            guard let image = NSImage(data: data) else { return .failed("Couldn't read the rendered diagram.") }
            image.size = size
            return .diagram(image, size)
        } catch {
            let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
            return .failed(Self.clean(message ?? error.localizedDescription))
        }
    }

    /// Mermaid's parse errors lead with a generic "Error: ".
    private static func clean(_ message: String) -> String {
        message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
    }
}
#endif
