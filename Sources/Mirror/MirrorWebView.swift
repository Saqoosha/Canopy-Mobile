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

struct MirrorWebView: UIViewRepresentable {
    let link: MirrorLink
    let attached: MirrorLink.Attached

    static let handlerNames = ["vscodeHost", "consoleLog", "canopyLink", "canopyInputWidth"]

    func makeCoordinator() -> Coordinator { Coordinator(link: link) }

    func makeUIView(context: Context) -> WKWebView {
        let prepared = MirrorWebViewPool.take()
        prepared.handler.link = link
        prepared.handler.entryHTML = attached.html
        prepared.handler.cache = MirrorAssetCache(version: attached.extensionVersion)
        prepared.proxy.target = context.coordinator
        let ucc = prepared.webView.configuration.userContentController
        for script in attached.userScripts {
            ucc.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.atDocumentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let webView = prepared.webView
        webView.navigationDelegate = context.coordinator
        link.onFrame = { [weak webView, weak coordinator = context.coordinator] line in
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
        context.coordinator.deliver = link.onFrame
        webView.load(URLRequest(url: MirrorAssetSchemeHandler.entryURL))
        DispatchQueue.main.async { MirrorWebViewPool.warm() }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        for name in handlerNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.link?.onFrame = nil
        coordinator.deliver = nil
        coordinator.queued = []
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var link: MirrorLink?
        /// Frames that arrived before the page could receive them, in the order the Mac sent them.
        var queued: [String] = []
        private(set) var pageIsReady = false
        var deliver: ((String) -> Void)?

        init(link: MirrorLink) {
            self.link = link
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageIsReady = true
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
        let proxy = WeakMessageProxy()
        for name in MirrorWebView.handlerNames {
            ucc.add(proxy, name: name)
        }
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        return Prepared(webView: webView, handler: handler, proxy: proxy)
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
