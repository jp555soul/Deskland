// macOS host for the Deskland Preview theme pages (GPL-3.0, see LICENSE).
// Shared plumbing: app identity and paths, log, JSON helpers, saved settings, theme manifest, UI strings.

import Foundation

enum App {
    static let name: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Islet"
    static let bundleID: String = Bundle.main.bundleIdentifier ?? "dev.islet.Islet"
    static let version: String = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    static let upstreamSite = URL(string: "https://deskland.app/")!
    static let commandNotification = Notification.Name(bundleID + ".command")

    private static let env = ProcessInfo.processInfo.environment

    private static func isDir(_ url: URL, containing file: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(file).path)
    }

    /// Settings and log. WALLPAPER_PROFILE_DIR isolates a test run from the real profile.
    static let dataDir: URL = {
        if let o = env["WALLPAPER_PROFILE_DIR"], !o.isEmpty { return URL(fileURLWithPath: o, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(name, isDirectory: true)
    }()

    /// The upstream `prototype/` folder: theme pages, settings page, themes.json, i18n.
    /// WALLPAPER_PAGE_DIR points the app at a checkout so pages can be edited and reloaded live.
    static let pageDir: URL = {
        if let p = env["WALLPAPER_PAGE_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true).standardizedFileURL }
        if let r = Bundle.main.resourceURL {
            let u = r.appendingPathComponent("prototype", isDirectory: true)
            if isDir(u, containing: "themes.json") { return u.standardizedFileURL }
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        for _ in 0..<6 {
            let u = dir.appendingPathComponent("prototype", isDirectory: true)
            if isDir(u, containing: "themes.json") { return u.standardizedFileURL }
            dir.deleteLastPathComponent()
        }
        return (Bundle.main.resourceURL ?? dir).appendingPathComponent("prototype", isDirectory: true).standardizedFileURL
    }()

    /// Mac-only web resources: the bridge shim and the string overrides.
    static let macWebDir: URL = {
        if let r = Bundle.main.resourceURL {
            let u = r.appendingPathComponent("mac-web", isDirectory: true)
            if isDir(u, containing: "host-shim.js") { return u }
        }
        return pageDir.deletingLastPathComponent().appendingPathComponent("mac/web", isDirectory: true)
    }()

    static var shareDir: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent(name, isDirectory: true)
    }
}

enum Log {
    static let url = App.dataDir.appendingPathComponent("host.log")
    private static let queue = DispatchQueue(label: "host.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ msg: String) {
        let line = stamp.string(from: Date()) + " " + msg + "\n"
        guard let data = line.data(using: .utf8) else { return }
        queue.async {
            FileHandle.standardError.write(data)
            let fm = FileManager.default
            try? fm.createDirectory(at: App.dataDir, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber, size.intValue > 1_000_000 {
                let old = App.dataDir.appendingPathComponent("host.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                h.closeFile()
            } else {
                try? data.write(to: url)
            }
        }
    }
}

enum JSON {
    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])
    }
    static func parse(_ s: String) -> Any? {
        guard let d = s.data(using: .utf8) else { return nil }
        return parse(d)
    }
    static func data(_ o: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(o) else { return nil }
        return try? JSONSerialization.data(withJSONObject: o, options: [])
    }
    static func string(_ o: [String: Any]) -> String {
        guard let d = data(o), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
    /// A string as a JavaScript string literal, quotes included.
    static func literal(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: []),
              let a = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(a.dropFirst().dropLast())
    }
}

/// Current theme plus the parameters the user changed per theme (unchanged ones use the theme defaults).
/// Same file format as the Windows host: {"version":1,"theme":…,"lang":…,"params":{theme:{key:value}}}.
enum Settings {
    static let url = App.dataDir.appendingPathComponent("settings.json")
    static var theme = "beach"
    static var lang = "auto"
    static var params: [String: [String: Any]] = [:]

    static func load() {
        guard let d = try? Data(contentsOf: url) else { return }
        guard let root = JSON.parse(d) as? [String: Any] else {
            Log.write("settings.json is unreadable, using defaults")
            return
        }
        if let v = root["theme"] as? String { theme = v }
        if let v = root["lang"] as? String { lang = v }
        if let p = root["params"] as? [String: Any] {
            for (k, v) in p { if let d = v as? [String: Any] { params[k] = d } }
        }
        Log.write("settings loaded, theme \(theme)")
    }

    static func save() {
        let root: [String: Any] = ["version": 1, "theme": theme, "lang": lang, "params": params]
        guard let d = JSON.data(root) else { Log.write("settings could not be encoded"); return }
        do {
            try FileManager.default.createDirectory(at: App.dataDir, withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
        } catch {
            Log.write("saving settings failed: \(error.localizedDescription)")
        }
    }
}

/// prototype/themes.json. Only themes marked ready and free can be loaded; the locked ones carry
/// a name, a description and a thumbnail but no page.
enum Themes {
    static func find(_ id: String) -> [String: Any]? {
        guard let d = try? Data(contentsOf: App.pageDir.appendingPathComponent("themes.json")),
              let root = JSON.parse(d) as? [String: Any],
              let list = root["themes"] as? [[String: Any]] else {
            Log.write("themes.json could not be read from \(App.pageDir.path)")
            return nil
        }
        return list.first { ($0["id"] as? String) == id && ($0["status"] as? String) == "ready" }
    }

    static func page(for id: String) -> String? {
        find(id)?["page"] as? String
    }

    static func allowed(_ id: String) -> Bool {
        guard let t = find(id), t["page"] is String else { return false }
        return (t["product"] as? String) == "free"
    }
}

/// UI strings come from prototype/i18n/<code>.json with mac/web/i18n/<code>.json merged over them,
/// so Windows wording is replaced without touching the upstream files. The merged table is what the
/// settings page fetches and what the menu bar uses.
enum I18n {
    static let supported = ["zh-CN", "en"]
    static var code = "en"
    static var sys = "en"
    private static var cur: [String: Any] = [:]
    private static var en: [String: Any] = [:]
    private static var zh: [String: Any] = [:]

    static func systemLanguage() -> String {
        let first = (Locale.preferredLanguages.first ?? "en").lowercased()
        return first.hasPrefix("zh") ? "zh-CN" : "en"
    }

    private static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = out[k] as? [String: Any], let o = v as? [String: Any] { out[k] = merge(b, o) } else { out[k] = v }
        }
        return out
    }

    static func merged(_ code: String) -> [String: Any]? {
        guard !code.isEmpty, code.allSatisfy({ ($0.isLetter && $0.isASCII) || $0 == "-" }) else { return nil }
        guard let d = try? Data(contentsOf: App.pageDir.appendingPathComponent("i18n/\(code).json")),
              let base = JSON.parse(d) as? [String: Any] else { return nil }
        guard let text = try? String(contentsOf: App.macWebDir.appendingPathComponent("i18n/\(code).json"), encoding: .utf8),
              let over = JSON.parse(text.replacingOccurrences(of: "{app}", with: App.name)) as? [String: Any] else { return base }
        return merge(base, over)
    }

    static func mergedData(_ code: String) -> Data? {
        guard let m = merged(code) else { return nil }
        return JSON.data(m)
    }

    static func load(_ setting: String) {
        sys = systemLanguage()
        code = supported.contains(setting) ? setting : sys
        zh = (merged("zh-CN")?["host"] as? [String: Any]) ?? [:]
        en = (merged("en")?["host"] as? [String: Any]) ?? [:]
        cur = code == "zh-CN" ? zh : en
        Log.write("language \(code) (setting \(setting), system \(sys))")
    }

    /// Current language, then English, then Chinese; {name} placeholders are filled from vars.
    static func t(_ key: String, _ vars: [String: String] = [:]) -> String {
        var s = (cur[key] as? String) ?? (en[key] as? String) ?? (zh[key] as? String) ?? key
        for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        return s
    }
}

/// Start at login: a per-user LaunchAgent that opens the app with --autostart (no settings window).
enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(App.bundleID).plist")
    }

    private static var arguments: [String] {
        ["/usr/bin/open", "-g", "-a", Bundle.main.bundlePath, "--args", "--autostart"]
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func set(_ on: Bool) {
        let fm = FileManager.default
        do {
            if on {
                let plist: [String: Any] = [
                    "Label": App.bundleID,
                    "ProgramArguments": arguments,
                    "RunAtLoad": true,
                    "LimitLoadToSessionType": "Aqua",
                ]
                let d = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: plistURL, options: .atomic)
                Log.write("start at login on (\(plistURL.path))")
            } else if fm.fileExists(atPath: plistURL.path) {
                try fm.removeItem(at: plistURL)
                Log.write("start at login off")
            }
        } catch {
            Log.write("changing start at login failed: \(error.localizedDescription)")
        }
    }

    /// The agent stores the app's path; rewrite it if the app has been moved since it was enabled.
    static func refreshPath() {
        guard isEnabled,
              let d = try? Data(contentsOf: plistURL),
              let p = (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [String: Any],
              let args = p["ProgramArguments"] as? [String], args != arguments else { return }
        set(true)
    }
}
