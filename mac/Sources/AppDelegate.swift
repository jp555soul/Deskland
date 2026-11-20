// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// App lifetime: menu bar item, wallpaper window, settings window, and the messages between them.
// Mirrors HostContext in host/DesktopHost.cs.

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let showSettingsAtLaunch: Bool
    private var statusItem: NSStatusItem?
    private var settingsItem, pauseItem, reloadItem, autostartItem, accessItem, quitItem: NSMenuItem?
    private var wallpaper: WallpaperController?
    private var settingsWin: SettingsWindowController?
    private let icons = IconReader()
    private let pauseMonitor = PauseMonitor()
    private var manualPause = false
    private var saveTimer: Timer?
    private var lastShare: URL?

    init(showSettings: Bool) {
        showSettingsAtLaunch = showSettings
        super.init()
    }

    // MARK: lifetime

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("start \(App.name) \(App.version), pages at \(App.pageDir.path)" + (showSettingsAtLaunch ? "" : " (login launch)"))
        Settings.load()
        I18n.load(Settings.lang)
        LoginItem.refreshPath()
        buildMainMenu()
        buildStatusItem()

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(onCommand(_:)), name: App.commandNotification,
                                                            object: nil, suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(self, selector: #selector(onScreensChanged(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(onScreensChanged(_:)), name: NSWorkspace.didWakeNotification, object: nil)

        icons.onChange = { [weak self] snap in self?.wallpaper?.setIcons(snap) }
        pauseMonitor.onChange = { [weak self] paused in self?.wallpaper?.autoPause = paused }

        WebHost.prepare { [weak self] in
            guard let self = self else { return }
            self.startWallpaper()
            self.icons.start()
            self.pauseMonitor.start()
            if self.showSettingsAtLaunch { self.openSettings() }
            if !IconReader.isTrusted { IconReader.requestTrust() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again while it runs opens Settings, as upstream does.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if saveTimer != nil { Settings.save() }
        icons.stop()
        wallpaper?.close()        // the system wallpaper was never changed, so it is simply visible again
        Log.write("quit")
    }

    @objc private func onCommand(_ note: Notification) {
        switch note.object as? String {
        case "exit": NSApp.terminate(nil)
        case "menu": statusItem?.button?.performClick(nil)
        default: openSettings()
        }
    }

    @objc private func onScreensChanged(_ note: Notification) {
        wallpaper?.relayout()
        icons.kick()
    }

    // MARK: menus

    /// Not shown (the app has no Dock icon), but it is what makes ⌘W, ⌘Q, ⌘C work in Settings.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(App.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "beach.umbrella.fill", accessibilityDescription: App.name)
                ?? NSImage(systemSymbolName: "photo.fill", accessibilityDescription: App.name)
            image?.isTemplate = true
            button.image = image
            if image == nil { button.title = "≋" }
            button.toolTip = App.name
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        func add(_ action: Selector, key: String = "") -> NSMenuItem {
            let m = NSMenuItem(title: "", action: action, keyEquivalent: key)
            m.target = self
            menu.addItem(m)
            return m
        }
        settingsItem = add(#selector(openSettingsAction), key: ",")
        pauseItem = add(#selector(togglePause))
        reloadItem = add(#selector(reloadWallpaper))
        autostartItem = add(#selector(toggleAutostart))
        accessItem = add(#selector(openAccessibilitySettings))
        menu.addItem(.separator())
        quitItem = add(#selector(quit), key: "q")
        item.menu = menu
        statusItem = item
        applyMenuTexts()
    }

    private func applyMenuTexts() {
        settingsItem?.title = I18n.t("traySettings")
        pauseItem?.title = I18n.t("trayPause")
        reloadItem?.title = I18n.t("trayReload")
        autostartItem?.title = I18n.t("trayAutostart")
        accessItem?.title = I18n.t("trayAccess")
        quitItem?.title = I18n.t("trayExit")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem?.state = manualPause ? .on : .off
        autostartItem?.state = LoginItem.isEnabled ? .on : .off
        accessItem?.isHidden = IconReader.isTrusted
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func togglePause() {
        manualPause.toggle()
        wallpaper?.manualPause = manualPause
    }

    @objc private func reloadWallpaper() {
        if wallpaper == nil { startWallpaper() } else { wallpaper?.reload() }
        icons.kick()
    }

    @objc private func toggleAutostart() {
        LoginItem.set(!LoginItem.isEnabled)
        settingsWin?.post(JSON.string(["t": "autostart", "v": LoginItem.isEnabled]))
    }

    @objc private func openAccessibilitySettings() {
        IconReader.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: wallpaper

    private func startWallpaper() {
        if !Themes.allowed(Settings.theme) { Settings.theme = Themes.allowed("beach") ? "beach" : "meadow" }
        guard Themes.allowed(Settings.theme), let page = Themes.page(for: Settings.theme) else {
            Log.write("no loadable theme in \(App.pageDir.path)")
            let alert = NSAlert()
            alert.messageText = App.name
            alert.informativeText = I18n.t("errNoPage", ["path": App.pageDir.appendingPathComponent("themes.json").path])
            alert.runModal()
            return
        }
        let w = WallpaperController(page: page)
        w.settingsJSON = { JSON.string(["t": "settings", "v": Settings.params[Settings.theme] ?? [:]]) }
        w.onIconsChanged = { [weak self] json in self?.settingsWin?.post(json) }
        w.onRecordProgress = { [weak self] p in self?.settingsWin?.post("{\"t\":\"recProgress\",\"p\":\(Double(p) ?? 0)}") }
        w.manualPause = manualPause
        wallpaper = w
        w.show()
    }

    // MARK: settings window

    private func openSettings() {
        if settingsWin == nil {
            let s = SettingsWindowController()
            s.onMessage = { [weak self] msg in self?.onSettingsMessage(msg) }
            s.onClose = { [weak self] in self?.settingsWin = nil }
            settingsWin = s
            Log.write("settings opened")
        }
        settingsWin?.show()
    }

    private func saveSoon() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.saveTimer = nil
            Settings.save()
        }
    }

    /// Messages from settings.html: hello / set / reset / theme / lang / autostart / share…
    private func onSettingsMessage(_ text: String) {
        guard let m = JSON.parse(text) as? [String: Any], let win = settingsWin else { return }
        switch m["t"] as? String {
        case "hello":
            let px = WallpaperController.screenPixels
            win.post(JSON.string([
                "t": "init", "theme": Settings.theme, "params": Settings.params,
                "screen": ["w": px.w, "h": px.h], "autostart": LoginItem.isEnabled,
                "autostartWarn": false, "autostartSw": "",
                "lang": Settings.lang, "langEff": I18n.code, "langSys": I18n.sys,
            ]))
            if let last = wallpaper?.lastIcons, !last.isEmpty { win.post(last) }

        case "set":
            guard let theme = m["theme"] as? String, let key = m["key"] as? String, let value = m["value"] else { return }
            Settings.params[theme, default: [:]][key] = value
            if theme == Settings.theme { wallpaper?.post(JSON.string(["t": "settings", "v": [key: value]])) }
            saveSoon()

        case "reset":
            guard let theme = m["theme"] as? String else { return }
            Settings.params.removeValue(forKey: theme)
            if theme == Settings.theme { wallpaper?.post("{\"t\":\"reset\"}") }
            saveSoon()
            Log.write("defaults restored for \(theme)")

        case "theme":
            guard let id = m["id"] as? String, Themes.allowed(id), let page = Themes.page(for: id) else {
                win.post(JSON.string(["t": "themeChanged", "id": Settings.theme]))
                Log.write("refused switch to unknown or locked theme")
                return
            }
            if id == Settings.theme { return }
            Settings.theme = id
            saveSoon()
            wallpaper?.loadPage(page)
            Log.write("theme \(id)")

        case "lang":
            guard let v = m["v"] as? String else { return }
            Settings.lang = v
            saveSoon()
            I18n.load(v)
            applyMenuTexts()
            win.post(JSON.string(["t": "lang", "v": Settings.lang, "eff": I18n.code, "sys": I18n.sys]))

        case "autostart":
            LoginItem.set((m["v"] as? Bool) ?? false)
            win.post(JSON.string(["t": "autostart", "v": LoginItem.isEnabled]))

        case "share":
            guard let w = wallpaper else { postShareFailure(I18n.t("errNotReady"), video: false); return }
            w.requestSnapshot { [weak self] thumb, png, error in self?.onShareImage(thumb, png, error) }

        case "shareVideo":
            guard let w = wallpaper else { postShareFailure(I18n.t("errNotReady"), video: true); return }
            w.requestRecording { [weak self] mime, poster, video, error in self?.onShareVideo(mime, poster, video, error) }

        case "openShare":
            if let u = lastShare, FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u) }

        case "revealShare":
            if let u = lastShare, FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.activateFileViewerSelecting([u]) }

        case "openWebsite":
            NSWorkspace.shared.open(App.upstreamSite)

        default:
            break      // update and purchase messages belong to upstream's store builds
        }
    }

    // MARK: share — the page renders these from icon positions with sample icons; nothing is captured

    private func postShareFailure(_ message: String, video: Bool) {
        var m: [String: Any] = ["t": "shareResult", "ok": false, "msg": message]
        if video { m["kind"] = "video" }
        settingsWin?.post(JSON.string(m))
    }

    private func decode(dataURL: String) -> Data? {
        let payload = dataURL.firstIndex(of: ",").map { dataURL[dataURL.index(after: $0)...] } ?? dataURL[...]
        return Data(base64Encoded: String(payload), options: .ignoreUnknownCharacters)
    }

    private func shareFile(ext: String) throws -> URL {
        let dir = App.shareDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return dir.appendingPathComponent("\(App.name) \(f.string(from: Date())).\(ext)")
    }

    private func onShareImage(_ thumb: String?, _ png: String?, _ failure: String?) {
        guard failure == nil, let png = png, let data = decode(dataURL: png) else {
            Log.write("share image failed: \(failure ?? "no data")")
            postShareFailure(failure ?? I18n.t("errNoImage"), video: false)
            return
        }
        do {
            let url = try shareFile(ext: "png")
            try data.write(to: url, options: .atomic)
            lastShare = url
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            Log.write("share image saved: \(url.path)")
            settingsWin?.post(JSON.string(["t": "shareResult", "ok": true, "thumb": thumb ?? "", "path": url.path]))
        } catch {
            Log.write("saving share image failed: \(error.localizedDescription)")
            postShareFailure(error.localizedDescription, video: false)
        }
    }

    private func onShareVideo(_ mime: String?, _ poster: String?, _ video: String?, _ failure: String?) {
        guard failure == nil, let video = video, let data = decode(dataURL: video) else {
            Log.write("share clip failed: \(failure ?? "no data")")
            postShareFailure(failure ?? I18n.t("errNoVideo"), video: true)
            return
        }
        do {
            let url = try shareFile(ext: mime == "video/webm" ? "webm" : "mp4")
            try data.write(to: url, options: .atomic)
            lastShare = url
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            AppSchemeHandler.shared.shareDir = url.deletingLastPathComponent()
            var c = URLComponents()
            c.scheme = AppSchemeHandler.scheme
            c.host = "share"
            c.path = "/" + url.lastPathComponent
            Log.write("share clip saved: \(url.path) (\(data.count / 1024) KB)")
            settingsWin?.post(JSON.string([
                "t": "shareResult", "ok": true, "kind": "video", "thumb": poster ?? "",
                "path": url.path, "url": c.url?.absoluteString ?? "",
            ]))
        } catch {
            Log.write("saving share clip failed: \(error.localizedDescription)")
            postShareFailure(error.localizedDescription, video: true)
        }
    }
}
