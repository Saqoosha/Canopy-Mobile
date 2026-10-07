import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.canopy-app", category: "MirrorWebView")

/// Serves the entry page and, through the link, the Mac extension's assets.
@MainActor
final class MirrorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "canopy-asset"
    static let entryURL = URL(string: "canopy-asset://ext/__entry.html")!

    /// Set when the pooled webview is handed to an attach; nil while it waits in the pool.
    weak var link: MirrorLink?
    var entryHTML = ""
    var cache: MirrorAssetCache?
    private var live: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let key = ObjectIdentifier(task)
        live.insert(key)
        if url.path == "/__entry.html" {
            finish(task, key: key, data: Data(entryHTML.utf8), mime: "text/html", url: url)
            return
        }
        let path = String(url.path.drop { $0 == "/" })
        if let cached = cache?.load(path: path) {
            finish(task, key: key, data: cached.data, mime: cached.mime, url: url)
            return
        }
        Task { @MainActor in
            do {
                guard let link else { throw MirrorLink.AssetError.closed }
                let asset = try await link.requestAsset(path: path)
                cache?.store(path: path, data: asset.data, mime: asset.mime)
                finish(task, key: key, data: asset.data, mime: asset.mime, url: url)
            } catch {
                logger.error("asset \(path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                guard live.remove(key) != nil else { return }
                task.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private func finish(_ task: any WKURLSchemeTask, key: ObjectIdentifier, data: Data, mime: String, url: URL) {
        // A stopped task raises an Objective-C exception on any further call.
        guard live.remove(key) != nil else { return }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }
}

/// The webview of one attach, kept by its model so a session reopened from `MirrorSessionCache`
/// shows the same page, already filled, instead of loading and replaying it again.
@MainActor
final class MirrorPage {
    fileprivate var webView: WKWebView?
    fileprivate var coordinator: MirrorWebView.Coordinator?
    fileprivate var handler: MirrorAssetSchemeHandler?
    fileprivate var proxy: WeakMessageProxy?

    /// Unhooks the page from its link. Not done when the view leaves the screen: a parked page keeps receiving frames.
    func close() {
        _ = retire()
    }

    /// Unhooks the page like `close` but hands back its webview, still showing the last conversation it drew.
    func retire() -> RetiredMirrorPage? {
        let kept = webView.map { RetiredMirrorPage(webView: $0, handler: handler, proxy: proxy) }
        if let webView {
            for name in MirrorWebView.handlerNames {
                webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
            }
        }
        coordinator?.link?.onFrame = nil
        coordinator?.deliver = nil
        coordinator?.queued = []
        handler?.link = nil
        webView = nil
        coordinator = nil
        handler = nil
        proxy = nil
        return kept
    }

    /// Takes a retired page back onto `link`, which resumed it: the page keeps what it drew and gets the frames it missed.
    func adopt(_ retired: RetiredMirrorPage, link: MirrorLink) {
        guard webView == nil, let handler = retired.handler, let proxy = retired.proxy else { return }
        let coordinator = MirrorWebView.Coordinator(link: link, pageIsReady: true)
        handler.link = link
        proxy.target = coordinator
        let ucc = retired.webView.configuration.userContentController
        for name in MirrorWebView.handlerNames { ucc.add(proxy, name: name) }
        retired.webView.navigationDelegate = coordinator
        MirrorWebView.connect(link, to: retired.webView, coordinator: coordinator)
        self.webView = retired.webView
        self.coordinator = coordinator
        self.handler = handler
        self.proxy = proxy
    }

    /// Waits until the drawn conversation stops growing: two equal heights 150 ms apart, or 3 s at most.
    func waitUntilDrawn() async {
        var last = -1
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(150))
            guard let webView, let height = try? await webView.evaluateJavaScript(
                "window.__canopyConversationHeight?.() ?? 0") as? Int else { return }
            if height > 0, height == last { return }
            last = height
        }
    }
}

/// A page whose link is gone, with what it takes to put it on another link.
@MainActor
struct RetiredMirrorPage {
    let webView: WKWebView
    fileprivate let handler: MirrorAssetSchemeHandler?
    fileprivate let proxy: WeakMessageProxy?
    /// Where it stands, set by its model from the link it retired from; nil when it cannot resume.
    var resumePoint: MirrorResumePoint? = nil
}

/// A retired page shown over a reattach until the new page has drawn the conversation. Its link is gone, so it
/// takes no touches.
struct MirrorStalePageView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

struct MirrorWebView: UIViewRepresentable {
    let link: MirrorLink
    let attached: MirrorLink.Attached
    let page: MirrorPage
    /// Settings › Composer. Off turns the page's Return-sends into a newline.
    let sendWithReturn: Bool

    static let handlerNames = ["vscodeHost", "consoleLog", "canopyLink", "canopyInputWidth"]

    func makeCoordinator() -> Coordinator {
        if let kept = page.coordinator { return kept }
        let coordinator = Coordinator(link: link)
        page.coordinator = coordinator
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        if let kept = page.webView { return kept }
        let prepared = MirrorWebViewPool.take()
        prepared.handler.link = link
        prepared.handler.entryHTML = attached.html
        prepared.handler.cache = MirrorAssetCache(version: attached.extensionVersion)
        prepared.proxy.target = context.coordinator
        let ucc = prepared.webView.configuration.userContentController
        ucc.addUserScript(WKUserScript(source: Self.sendWithReturnScript(sendWithReturn), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        context.coordinator.sendWithReturn = sendWithReturn
        for script in attached.userScripts {
            ucc.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.atDocumentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let webView = prepared.webView
        webView.navigationDelegate = context.coordinator
        Self.connect(link, to: webView, coordinator: context.coordinator)
        webView.load(URLRequest(url: MirrorAssetSchemeHandler.entryURL))
        page.webView = webView
        page.handler = prepared.handler
        page.proxy = prepared.proxy
        DispatchQueue.main.async { MirrorWebViewPool.warm() }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.sendWithReturn != sendWithReturn else { return }
        context.coordinator.sendWithReturn = sendWithReturn
        webView.evaluateJavaScript(Self.sendWithReturnScript(sendWithReturn))
    }

    /// Routes `link`'s frames into the page.
    fileprivate static func connect(_ link: MirrorLink, to webView: WKWebView, coordinator: Coordinator) {
        link.onFrame = { [weak webView, weak coordinator] line in
            // The page cannot receive a postMessage until its own scripts run; frames that
            // arrive first wait for didFinish. Weak, or the coordinator's own `deliver`
            // would hold this closure and neither would ever be released.
            guard let coordinator else { return }
            guard coordinator.pageIsReady else {
                coordinator.queued.append(line)
                return
            }
            // As a string literal, not source: JSON allows U+2028/2029 where JavaScript source does not.
            guard let literal = try? JSONSerialization.data(withJSONObject: [line]),
                  let array = String(data: literal, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("window.postMessage(JSON.parse(\(array)[0]),'*')") { _, error in
                if let error { logger.error("deliver failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        coordinator.deliver = link.onFrame
    }

    fileprivate static func sendWithReturnScript(_ on: Bool) -> String {
        "window.__canopyReturnSends=\(on)"
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var link: MirrorLink?
        /// Frames that arrived before the page could receive them, in the order the Mac sent them.
        var queued: [String] = []
        private(set) var pageIsReady = false
        var sendWithReturn = false
        var deliver: ((String) -> Void)?

        init(link: MirrorLink, pageIsReady: Bool = false) {
            self.link = link
            self.pageIsReady = pageIsReady
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            // A reload after a web content crash starts an empty page again; frames must wait for it too.
            pageIsReady = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageIsReady = true
            // A reload re-runs the document-start script with the value from when the view opened.
            webView.evaluateJavaScript(MirrorWebView.sendWithReturnScript(sendWithReturn))
            let waiting = queued
            queued = []
            waiting.forEach { deliver?($0) }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            logger.error("web content process terminated; reloading")
            webView.reload()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            logger.error("entry page failed to load: \(error.localizedDescription, privacy: .public)")
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "vscodeHost":
                if let body = message.body as? [String: Any] {
                    link?.send(body)
                }
            case "consoleLog":
                logger.notice("[js] \(String(describing: message.body), privacy: .private)")
            case "canopyLink":
                if let text = message.body as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) {
                    UIApplication.shared.open(url)
                }
            default:
                break
            }
        }
    }
}

/// One webview built and started ahead of a live attach, with its scheme and message handlers already registered, so a tap only fills in the page.
@MainActor
enum MirrorWebViewPool {
    struct Prepared {
        let webView: WKWebView
        let handler: MirrorAssetSchemeHandler
        let proxy: WeakMessageProxy
    }

    private static var spare: Prepared?

    static func warm() {
        guard spare == nil else { return }
        spare = make()
    }

    /// The pooled webview, or a fresh one when the pool is empty. Each is used for one attach only.
    static func take() -> Prepared {
        if let ready = spare {
            spare = nil
            return ready
        }
        return make()
    }

    private static func make() -> Prepared {
        let config = WKWebViewConfiguration()
        let handler = MirrorAssetSchemeHandler()
        config.setURLSchemeHandler(handler, forURLScheme: MirrorAssetSchemeHandler.scheme)
        let ucc = config.userContentController
        // iOS zooms into a focused input under 16px, pushing the composer off screen.
        ucc.addUserScript(WKUserScript(
            source: "document.querySelector('meta[name=viewport]')?.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover')",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        // The subagents pill wraps the composer toolbar onto a second row at phone width;
        // wider layouts (iPad) have room and keep it.
        // Matched by its data attribute: the class name carries a per-build hash.
        ucc.addUserScript(WKUserScript(
            source: "document.head.appendChild(Object.assign(document.createElement('style'),{textContent:'@media (max-width:600px){button[data-agents-dot]{display:none!important}}'}))",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        // The page sends on a bare Enter, and the on-screen Return is one. With the setting
        // off, Return inserts the line break Shift+Enter would; Cmd+Return still sends.
        // Only the contenteditable composer — the page's plain inputs keep their own Enter,
        // and an open slash / @ menu (a listbox) keeps Return as its pick.
        // An Enter the page does handle drops the keyboard once it has sent: the page gives no
        // send signal, so "the composer emptied" stands in for one. A menu pick (slash, @) leaves
        // text behind and keeps the keyboard up.
        ucc.addUserScript(WKUserScript(
            source: """
            addEventListener('focusin',e=>{if(e.target.isContentEditable)e.target.enterKeyHint=window.__canopyReturnSends?'send':'enter'},true);
            addEventListener('keydown',e=>{const t=e.target;if(e.key!=='Enter'||e.shiftKey||e.altKey||e.isComposing||e.keyCode===229||!t.isContentEditable)return;if(!window.__canopyReturnSends&&!e.metaKey&&!e.ctrlKey&&!document.querySelector('[role=listbox]')){e.preventDefault();e.stopImmediatePropagation();document.execCommand('insertLineBreak');return}if(e.metaKey||e.ctrlKey||!t.textContent.trim())return;const sent=()=>{if(document.activeElement===t&&!t.textContent.trim())t.blur()};setTimeout(sent,50);setTimeout(sent,300)},true)
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        // Used by `MirrorPageWebView` when the page leaves and re-enters the window: a scroll area
        // within 8 px of its bottom goes back to its bottom, any other to where it was. Re-applied when
        // those areas resize, for a second or until a touch. Also the status bar tap: the tallest
        // scroll area (currently the conversation) goes to its top.
        ucc.addUserScript(WKUserScript(
            source: """
            (()=>{let saved=[];window.__canopySaveScroll=()=>{saved=[...document.querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+1&&/auto|scroll/.test(getComputedStyle(e).overflowY)).map(e=>({e,top:e.scrollTop,bottom:e.scrollHeight-e.scrollTop-e.clientHeight<8}))};window.__canopyRestoreScroll=()=>{const live=saved.filter(s=>s.e.isConnected);const apply=()=>live.forEach(s=>{s.e.scrollTop=s.bottom?s.e.scrollHeight:s.top});apply();const ro=new ResizeObserver(apply);live.forEach(s=>ro.observe(s.e));const stop=()=>{ro.disconnect();clearTimeout(t);removeEventListener('touchstart',stop,true)};const t=setTimeout(stop,1000);addEventListener('touchstart',stop,true)};window.__canopyScrollToTop=()=>{conversation()?.scrollTo({top:0,behavior:'smooth'})};window.__canopyConversationHeight=()=>conversation()?.scrollHeight??document.body.scrollHeight;function conversation(){return [...document.querySelectorAll('*')].filter(e=>e.scrollHeight>e.clientHeight+1&&/auto|scroll/.test(getComputedStyle(e).overflowY)).sort((a,b)=>b.clientHeight-a.clientHeight)[0]}})()
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let proxy = WeakMessageProxy()
        for name in MirrorWebView.handlerNames {
            ucc.add(proxy, name: name)
        }
        let webView = MirrorPageWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        return Prepared(webView: webView, handler: handler, proxy: proxy)
    }
}

/// Keeps the page's scroll position across leaving the window (a page parked by `MirrorSessionCache` does), and
/// makes a status bar tap scroll the conversation to its top.
///
/// Without the first, a page pinned to its bottom came back about a bar's height short of it. Likely cause, inferred
/// from the fix working: out of the window the webview loses the navigation bar's inset and clamps its scroll areas.
/// Saved in `willMove(toWindow:)`, before the removal; SwiftUI's `onDisappear` saved it and still drifted.
final class MirrorPageWebView: WKWebView {
    /// The status bar tap's target. The page scrolls inside its own elements, never the webview's scroll view, so
    /// a tap on that one does nothing. This stand-in forwards the tap; a second `scrollsToTop` view in the window
    /// would disable it.
    private let scrollToTopCatcher = UIScrollView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private let scrollToTopForwarder = ScrollToTopForwarder()

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        scrollView.scrollsToTop = false
        scrollToTopForwarder.webView = self
        scrollToTopCatcher.delegate = scrollToTopForwarder
        scrollToTopCatcher.scrollsToTop = true
        // 1 pt down, so it is not already at its top; the forwarder returns false, so it stays there.
        scrollToTopCatcher.contentSize = CGSize(width: 1, height: 3)
        scrollToTopCatcher.contentOffset = CGPoint(x: 0, y: 1)
        scrollToTopCatcher.showsVerticalScrollIndicator = false
        // As wide as the webview: at 1 pt wide it was the window's only candidate yet never asked (logged on device),
        // at full width it is. Probably UIKit only considers a scroll view spanning the tap's x; not documented.
        scrollToTopCatcher.autoresizingMask = [.flexibleWidth]
        addSubview(scrollToTopCatcher)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// A separate object: WKWebView is its own scroll view's delegate, and its handlers must not see the catcher.
    private final class ScrollToTopForwarder: NSObject, UIScrollViewDelegate {
        weak var webView: WKWebView?

        func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
            webView?.evaluateJavaScript("window.__canopyScrollToTop?.()")
            return false
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, window != nil {
            evaluateJavaScript("window.__canopySaveScroll?.()")
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            evaluateJavaScript("window.__canopyRestoreScroll?.()")
        }
    }
}

/// `WKUserContentController` retains its handlers; a weak proxy keeps the coordinator collectable.
@MainActor
final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
