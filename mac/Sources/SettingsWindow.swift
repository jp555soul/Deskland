// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// The settings window: an ordinary window showing prototype/settings.html. It exists only while
// open, because its live preview runs a second copy of the theme.

import Cocoa
import WebKit

final class SettingsWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    var onMessage: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let web: WKWebView
    private let bridge: Bridge

    override init() {
        let size = NSSize(width: 1120, height: 800)    // themes three across on the left, preview over parameters on the right
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        let bridge = Bridge()          // stored properties cannot be read before super.init
        self.bridge = bridge
        web = WebHost.makeWebView(frame: NSRect(origin: .zero, size: size), bridge: bridge)
        super.init()

        window.title = App.name
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 940, height: 680)
        window.titlebarAppearsTransparent = true
        // settings.html follows the system appearance: #ffffff light, #171717 dark.
        window.backgroundColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbRed: 0x17 / 255.0, green: 0x17 / 255.0, blue: 0x17 / 255.0, alpha: 1)
                : .white
        }
        window.contentView = web
        window.center()
        window.setFrameAutosaveName("Settings")
        window.delegate = self

        web.navigationDelegate = self
        bridge.onMessage = { [weak self] msg in self?.onMessage?(msg) }
        bridge.onAlert = { [weak self] text in self?.showAlert(text) }
        web.load(URLRequest(url: AppSchemeHandler.pageURL("settings.html", query: "v=" + App.version)))
    }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func post(_ json: String) {
        WebHost.post(json, to: web)
    }

    private func showAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = App.name
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    func windowWillClose(_ notification: Notification) {
        WebHost.detach(web)
        // Let AppKit finish closing before the owner drops this controller (and with it the window).
        DispatchQueue.main.async { self.onClose?() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("settings web content process ended, reloading")
        web.reload()
    }
}
