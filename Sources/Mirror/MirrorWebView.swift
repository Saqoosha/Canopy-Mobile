import SwiftUI
import WebKit
import os

private let logger = Logger(subsystem: "sh.saqoo.canopy-app", category: "MirrorWebView")

/// Serves the entry page and, through the link, the Mac extension's assets.
@MainActor
final class MirrorAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "canopy-asset"
    static let entryURL = URL(string: "canopy-asset://ext/__entry.html")!

    private weak var link: MirrorLink?
    private let entryHTML: String
    private var live: Set<ObjectIdentifier> = []

    init(link: MirrorLink, entryHTML: String) {
        self.link = link
        self.entryHTML = entryHTML
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let key = ObjectIdentifier(task)
        live.insert(key)
        if url.path == "/__entry.html" {
            finish(task, key: key, data: Data(entryHTML.utf8), mime: "text/html", url: url)
            return
        }
        let path = String(url.path.drop { $0 == "/" })
        Task { @MainActor in
            do {
                guard let link else { throw MirrorLink.AssetError.closed }
                let asset = try await link.requestAsset(path: path)
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
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MirrorAssetSchemeHandler(link: link, entryHTML: attached.html), forURLScheme: MirrorAssetSchemeHandler.scheme)
        let ucc = config.userContentController
        // iOS zooms into a focused input under 16px, pushing the composer off screen.
        ucc.addUserScript(WKUserScript(
            source: "document.querySelector('meta[name=viewport]')?.setAttribute('content','width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover')",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        for script in attached.userScripts {
            ucc.addUserScript(WKUserScript(
                source: script.source,
                injectionTime: script.atDocumentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: true
            ))
        }
        let proxy = WeakMessageProxy(target: context.coordinator)
        for name in Self.handlerNames {
            ucc.add(proxy, name: name)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = context.coordinator
        link.onFrame = { [weak webView] line in
            // As a string literal, not source: JSON allows U+2028/2029 where JavaScript source does not.
            guard let literal = try? JSONSerialization.data(withJSONObject: [line]),
                  let array = String(data: literal, encoding: .utf8)
            else { return }
            webView?.evaluateJavaScript("window.postMessage(JSON.parse(\(array)[0]),'*')") { _, error in
                if let error { logger.error("deliver failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
        webView.load(URLRequest(url: MirrorAssetSchemeHandler.entryURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        for name in handlerNames {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        coordinator.link?.onFrame = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var link: MirrorLink?

        init(link: MirrorLink) {
            self.link = link
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
                logger.notice("[js] \(String(describing: message.body), privacy: .public)")
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

/// `WKUserContentController` retains its handlers; a weak proxy keeps the coordinator collectable.
@MainActor
private final class WeakMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
