// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// Everything the web views share: the app:// scheme that serves the pages from disk, the script
// bridge that stands in for WebView2's message channel, and the rule that keeps pages offline.

import Cocoa
import WebKit

/// Serves app://local/<path> from the prototype folder and app://share/<file> from the folder
/// the last shared clip was saved to. Pages are loaded from here instead of file:// so that
/// fetch() and same-origin canvas reads work.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
    static let shared = AppSchemeHandler()
    static let scheme = "app"
    static func pageURL(_ page: String, query: String) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "local"
        c.path = "/" + page
        c.percentEncodedQuery = query
        return c.url!
    }

    var shareDir: URL?

    private static let types: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8", "css": "text/css; charset=utf-8", "svg": "image/svg+xml",
        "png": "image/png", "webp": "image/webp", "jpg": "image/jpeg", "jpeg": "image/jpeg", "ico": "image/x-icon",
        "mp4": "video/mp4", "webm": "video/webm",
    ]

    private func body(for url: URL) -> (Data, String)? {
        var rel = url.path
        while rel.hasPrefix("/") { rel.removeFirst() }
        if url.host == "share" {
            guard let dir = shareDir, !rel.isEmpty, !rel.contains("/"), !rel.hasPrefix(".") else { return nil }
            guard let d = try? Data(contentsOf: dir.appendingPathComponent(rel), options: .mappedIfSafe) else { return nil }
            return (d, (rel as NSString).pathExtension.lowercased())
        }
        if rel.isEmpty { rel = "settings.html" }
        let ext = (rel as NSString).pathExtension.lowercased()
        if rel.hasPrefix("i18n/"), ext == "json", !rel.dropFirst(5).contains("/") {
            guard let d = I18n.mergedData(String(rel.dropFirst(5).dropLast(5))) else { return nil }
            return (d, ext)
        }
        let root = App.pageDir.path
        let file = App.pageDir.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root + "/"), let d = try? Data(contentsOf: file) else { return nil }
        return (d, ext)
    }

    /// "bytes=a-b", "bytes=a-" or "bytes=-n" → half-open byte range. Media elements need this.
    private func byteRange(_ header: String, total: Int) -> Range<Int>? {
        guard total > 0, header.hasPrefix("bytes=") else { return nil }
        guard let first = header.dropFirst(6).split(separator: ",").first else { return nil }
        let spec = first.trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let n = Int(parts[1]), n > 0 else { return nil }
            return max(0, total - n)..<total
        }
        guard let a = Int(parts[0]), a >= 0, a < total else { return nil }
        let b = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? (total - 1), total - 1)
        return b >= a ? a..<(b + 1) : nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var status = 200
        var headers = ["Cache-Control": "no-store", "Access-Control-Allow-Origin": "*"]
        var payload: Data
        if let (data, ext) = body(for: url) {
            headers["Content-Type"] = AppSchemeHandler.types[ext] ?? "application/octet-stream"
            headers["Accept-Ranges"] = "bytes"
            payload = data
            if let h = urlSchemeTask.request.value(forHTTPHeaderField: "Range"), let r = byteRange(h, total: data.count) {
                status = 206
                payload = data.subdata(in: r)
                headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
            }
        } else {
            status = 404
            headers["Content-Type"] = "text/plain; charset=utf-8"
            payload = Data("not found".utf8)
            Log.write("page asked for a missing file: \(url.absoluteString)")
        }
        headers["Content-Length"] = String(payload.count)
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            urlSchemeTask.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(payload)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

/// Page → host messages. `host` carries what the pages post through chrome.webview;
/// `hostAlert` carries window.alert() text.
final class Bridge: NSObject, WKScriptMessageHandler {
    var onMessage: ((String) -> Void)?
    var onAlert: ((String) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let s = message.body as? String else { return }
        if message.name == "hostAlert" { onAlert?(s) } else { onMessage?(s) }
    }
}

enum WebHost {
    private static let shim: String = {
        let url = App.macWebDir.appendingPathComponent("host-shim.js")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else {
            Log.write("host-shim.js is missing at \(url.path); pages cannot reach the host")
            return ""
        }
        let safeName = App.name.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "'", with: "")
        return s.replacingOccurrences(of: "__APP_NAME__", with: safeName)
    }()

    /// Blocks every http(s)/ws(s) load from the pages. The app is local-only, like upstream.
    private static var offlineRules: WKContentRuleList?

    static func prepare(_ done: @escaping () -> Void) {
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
        """
        guard let store = WKContentRuleListStore.default() else { done(); return }
        store.compileContentRuleList(forIdentifier: "offline", encodedContentRuleList: rules) { list, error in
            DispatchQueue.main.async {
                offlineRules = list
                if let error = error { Log.write("offline rule did not compile: \(error.localizedDescription)") }
                done()
            }
        }
    }

    static func makeWebView(frame: NSRect, bridge: Bridge) -> WKWebView {
        let content = WKUserContentController()
        content.add(bridge, name: "host")
        content.add(bridge, name: "hostAlert")
        content.addUserScript(WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let rules = offlineRules { content.add(rules) }

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(AppSchemeHandler.shared, forURLScheme: AppSchemeHandler.scheme)
        config.mediaTypesRequiringUserActionForPlayback = []

        let web = WKWebView(frame: frame, configuration: config)
        web.autoresizingMask = [.width, .height]
        web.allowsMagnification = false
        web.setValue(false, forKey: "drawsBackground")   // let the window colour show until the page paints
        web.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) { web.isInspectable = true }
        return web
    }

    /// Host → page, delivered to the listeners the page registered on chrome.webview.
    static func post(_ json: String, to web: WKWebView) {
        web.evaluateJavaScript("window.__hostDispatch&&window.__hostDispatch(\(JSON.literal(json)));0", completionHandler: nil)
    }

    static func detach(_ web: WKWebView) {
        let content = web.configuration.userContentController
        content.removeScriptMessageHandler(forName: "host")
        content.removeScriptMessageHandler(forName: "hostAlert")
        web.stopLoading()
    }
}
