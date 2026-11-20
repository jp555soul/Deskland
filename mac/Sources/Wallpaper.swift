// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// The wallpaper itself: a borderless, click-through window at the desktop-picture level, which
// puts it above the system wallpaper and below Finder's icons, showing the current theme page.

import Cocoa
import WebKit

final class WallpaperController: NSObject, WKNavigationDelegate {
    /// The settings message for the current theme, sent first whenever a page reports ready.
    var settingsJSON: (() -> String)?
    /// Icon message as sent to the page, forwarded to the settings preview.
    var onIconsChanged: ((String) -> Void)?
    var onRecordProgress: ((String) -> Void)?

    private let window: NSWindow
    private let web: WKWebView
    private let bridge: Bridge
    private var page: String
    private var pageReady = false
    private var snapshot: IconSnapshot?
    private var lastPause: Bool?
    private(set) var lastIcons = ""

    var manualPause = false { didSet { pushPause() } }
    var autoPause = false { didSet { pushPause() } }

    static var screen: NSScreen? { NSScreen.screens.first }   // the display with the menu bar, like upstream's primary monitor

    /// Size of the wallpaper in device pixels, the unit the pages expect.
    static var screenPixels: (w: Int, h: Int) {
        guard let s = screen else { return (1920, 1080) }
        return (Int((s.frame.width * s.backingScaleFactor).rounded()), Int((s.frame.height * s.backingScaleFactor).rounded()))
    }

    init(page: String) {
        self.page = page
        let frame = WallpaperController.screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let bridge = Bridge()          // stored properties cannot be read before super.init
        self.bridge = bridge
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        web = WebHost.makeWebView(frame: NSRect(origin: .zero, size: frame.size), bridge: bridge)
        super.init()

        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.hasShadow = false
        window.canHide = false
        window.animationBehavior = .none
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = NSColor(srgbRed: 26 / 255, green: 163 / 255, blue: 196 / 255, alpha: 1)
        window.contentView = web
        window.setFrame(frame, display: false)

        web.navigationDelegate = self
        bridge.onMessage = { [weak self] msg in self?.onPageMessage(msg) }
    }

    func show() {
        window.orderFrontRegardless()
        load()
        Log.write("wallpaper window up, \(Int(window.frame.width))x\(Int(window.frame.height)) pt at scale \(window.backingScaleFactor)")
    }

    func close() {
        WebHost.detach(web)
        window.orderOut(nil)
        window.close()
    }

    private func load() {
        pageReady = false
        web.load(URLRequest(url: AppSchemeHandler.pageURL(page, query: "wallpaper=1")))
    }

    /// Switching theme: the new page reports ready and is then sent settings, icons and pause again.
    func loadPage(_ newPage: String) {
        page = newPage
        load()
    }

    func reload() {
        load()
    }

    /// Displays were added, removed or changed resolution; also re-asserts the window after wake.
    func relayout() {
        guard let frame = WallpaperController.screen?.frame else { return }
        if window.frame != frame { window.setFrame(frame, display: true) }
        window.orderFrontRegardless()
        lastIcons = ""
        pushIcons()
    }

    func post(_ json: String) {
        WebHost.post(json, to: web)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.write("web content process ended, reloading the wallpaper page")
        load()
    }

    // MARK: page → host

    private func onPageMessage(_ msg: String) {
        if msg.hasPrefix("snapshot|") { onSnapshot(msg); return }
        if msg.hasPrefix("recprogress|") { onRecordProgress?(String(msg.dropFirst(12))); return }
        if msg.hasPrefix("record|") { onRecord(msg); return }
        // Anything else is the page saying it is ready: settings first (the shoreline depends on
        // them), then icons and the pause state.
        pageReady = true
        if let s = settingsJSON?() { post(s) }
        lastIcons = ""
        lastPause = nil
        pushIcons()
        pushPause()
        Log.write("page ready: \(page)")
    }

    // MARK: icons

    func setIcons(_ snap: IconSnapshot) {
        snapshot = snap
        pushIcons()
    }

    /// Icon rectangles as [left, top, right, bottom] in device pixels from the screen's top-left.
    private func pushIcons() {
        guard pageReady, let screen = WallpaperController.screen else { return }
        let snap = snapshot ?? IconSnapshot(visible: false, rects: [])
        let k = screen.backingScaleFactor
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        var parts: [String] = []
        for r in snap.rects where r.intersects(bounds) {
            let l = Int((r.minX * k).rounded()), t = Int((r.minY * k).rounded())
            let rt = Int((r.maxX * k).rounded()), b = Int((r.maxY * k).rounded())
            parts.append("[\(l),\(t),\(rt),\(b)]")
        }
        let json = "{\"t\":\"icons\",\"vis\":\(snap.visible ? "true" : "false"),\"r\":[\(parts.joined(separator: ","))]}"
        if json == lastIcons { return }
        lastIcons = json
        onIconsChanged?(json)
        post(json)
    }

    // MARK: pause

    private func pushPause() {
        guard pageReady else { return }
        let paused = manualPause || autoPause
        if lastPause == paused { return }
        lastPause = paused
        post("{\"t\":\"pause\",\"v\":\(paused ? "true" : "false")}")
        Log.write(paused ? "paused" : "running")
    }

    // MARK: share image — the page draws the picture itself from icon positions, nothing is captured

    private var snapshotDone: ((_ thumb: String?, _ png: String?, _ error: String?) -> Void)?
    private var snapshotTimeout: Timer?

    func requestSnapshot(_ done: @escaping (String?, String?, String?) -> Void) {
        guard pageReady else { done(nil, nil, I18n.t("errNotReady")); return }
        guard snapshotDone == nil else { done(nil, nil, I18n.t("errBusyImage")); return }
        snapshotDone = done
        snapshotTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            self?.finishSnapshot(nil, nil, I18n.t("errImageTimeout"))
        }
        post("{\"t\":\"snapshot\"}")
    }

    /// "snapshot|<thumbnail data URL>|<full PNG data URL>" or "snapshot|error|<message>"
    private func onSnapshot(_ msg: String) {
        let p = msg.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if p.count < 3 { finishSnapshot(nil, nil, I18n.t("errBadData")) }
        else if p[1] == "error" { finishSnapshot(nil, nil, p[2]) }
        else { finishSnapshot(p[1], p[2], nil) }
    }

    private func finishSnapshot(_ thumb: String?, _ png: String?, _ error: String?) {
        snapshotTimeout?.invalidate()
        snapshotTimeout = nil
        let done = snapshotDone
        snapshotDone = nil
        done?(thumb, png, error)
    }

    // MARK: share clip

    private var recordDone: ((_ mime: String?, _ poster: String?, _ video: String?, _ error: String?) -> Void)?
    private var recordTimeout: Timer?

    func requestRecording(_ done: @escaping (String?, String?, String?, String?) -> Void) {
        guard pageReady else { done(nil, nil, nil, I18n.t("errNotReady")); return }
        guard recordDone == nil else { done(nil, nil, nil, I18n.t("errBusyVideo")); return }
        recordDone = done
        recordTimeout = Timer.scheduledTimer(withTimeInterval: 45, repeats: false) { [weak self] _ in
            self?.finishRecord(nil, nil, nil, I18n.t("errVideoTimeout"))
        }
        post("{\"t\":\"record\"}")
    }

    /// "record|<mime>|<poster data URL>|<video data URL>" or "record|error|<message>"
    private func onRecord(_ msg: String) {
        let p = msg.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        if p.count >= 3, p[1] == "error" { finishRecord(nil, nil, nil, p[2...].joined(separator: "|")) }
        else if p.count < 4 { finishRecord(nil, nil, nil, I18n.t("errBadData")) }
        else { finishRecord(p[1], p[2], p[3], nil) }
    }

    private func finishRecord(_ mime: String?, _ poster: String?, _ video: String?, _ error: String?) {
        recordTimeout?.invalidate()
        recordTimeout = nil
        let done = recordDone
        recordDone = nil
        done?(mime, poster, video, error)
    }
}

/// Decides when the wallpaper should stop animating on its own: a normal window covers the whole
/// usable desktop (zoomed or full screen), or the displays are asleep / the session is locked.
final class PauseMonitor {
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var asleep = false
    private var covered = false
    private var last: Bool?

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.setAsleep(true) }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.setAsleep(false) }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setAsleep(true) }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.setAsleep(false) }
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.check() }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        check()
    }

    private func setAsleep(_ v: Bool) {
        asleep = v
        publish()
    }

    private func check() {
        let by = PauseMonitor.coveringApp()
        let now = by != nil
        if now != covered, let by = by { Log.write("desktop covered by \(by)") }
        covered = now
        publish()
    }

    private func publish() {
        let v = asleep || covered
        if v == last { return }
        last = v
        onChange?(v)
    }

    /// Owner of an on-screen normal-level window that hides the desktop between menu bar and Dock.
    /// Window bounds and owners are available without the Screen Recording permission.
    static func coveringApp() -> String? {
        guard let screen = WallpaperController.screen,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let vf = screen.visibleFrame
        // visibleFrame is bottom-left based; window bounds are top-left based.
        let usable = CGRect(x: vf.minX, y: screen.frame.maxY - vf.maxY, width: vf.width, height: vf.height).insetBy(dx: 8, dy: 8)
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.9,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                  r.contains(usable) else { continue }
            return (w[kCGWindowOwnerName as String] as? String) ?? "another app"
        }
        return nil
    }
}
