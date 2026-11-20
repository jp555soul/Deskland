# Islet — Deskland Preview for macOS

A community-contributed macOS host for the open-source [Deskland Preview](https://github.com/BLEZZ0102/Deskland) themes.
The theme pages in `prototype/` are used unchanged; this folder does on macOS what `host/` (C# + WebView2) does on
Windows, in Swift + WKWebView. Added November 2026. Licensed GPL-3.0 like the rest of the repository.

"Islet" is a working name with its own icon. [TRADEMARKS.md](../TRADEMARKS.md) asks builds that are not official
releases to use their own name and icon, so this one does not call itself Deskland. The name and bundle id are the
defaults at the top of `build.sh`, or `APP_NAME=… BUNDLE_ID=… mac/build.sh`.

> **Status:** experimental. It builds with no warnings on Apple Silicon and the web side has been tested against
> the real theme pages. [TESTING.md](TESTING.md) lists the manual checks; reading icon positions from Finder is the
> part most likely to vary between macOS versions.

## Build and run

Needs macOS 12 or later and Xcode's Command Line Tools (`xcode-select --install`).

```sh
mac/build.sh run
```

The app lands in `mac/build/Islet.app`. It has no Dock icon; look for the umbrella in the menu bar.

On first launch macOS asks for **Accessibility** access (System Settings → Privacy & Security → Accessibility).
That is how the app learns where Finder has put your desktop icons. Until it is allowed, the wallpaper runs but
is drawn as if the desktop were empty.

macOS ties that permission to the app's code signature. An ad-hoc signature changes on every build, so after a
rebuild the entry has to be removed and re-added. `build.sh` signs with your first "Apple Development" identity
if you have one, which keeps the permission; set `SIGN_ID` to choose another, or `SIGN_ID=-` to force ad hoc.

## What it does

| Windows host | This host |
| --- | --- |
| Child window of Progman / WorkerW under the icon layer | Borderless click-through window at the desktop-picture level, on every Space |
| Icon rectangles from the desktop ListView, polled every 400 ms | Icon rectangles from Finder's Accessibility tree; polled every second, four times a second for a few seconds after a mouse-up |
| Pause when the foreground window is maximized or full screen | Pause when a window covers the desktop between menu bar and Dock, and while displays sleep or the session is locked |
| Tray icon, Ctrl+Alt+H | Menu bar item (no global hotkey) |
| Start with Windows (Startup folder shortcut) | Start at login (`~/Library/LaunchAgents/<bundle id>.plist`) |
| `%LOCALAPPDATA%\DesklandPreview` | `~/Library/Application Support/Islet` (`settings.json`, `host.log`) |
| Shares saved to Pictures\Deskland Preview | Shares saved to `~/Pictures/Islet`, copied to the clipboard |
| `Deskland.exe --exit / --settings / --menu / --autostart` | `Islet.app/Contents/MacOS/Islet` with the same flags |

Like upstream it covers the primary display only (the one with the menu bar), and nothing is fetched from the
network: page loads to `http(s)` are blocked outright.

## How the pages run unmodified

- `web/host-shim.js` is injected before each page's scripts and provides `window.chrome.webview`
  (`postMessage`, `addEventListener('message')`) on top of WKWebView's message handlers. The message
  protocol is the one documented in `host/README.md`.
- Pages are served from `app://local/…` by a URL scheme handler, so `fetch()` and canvas reads work.
- `web/i18n/*.json` is merged over `prototype/i18n/*.json` when served, replacing Windows wording
  ("Start with Windows", the wallpaper-slideshow help) and explaining that locked themes are not part of this build.

## Working on themes

```sh
WALLPAPER_PAGE_DIR="$PWD/prototype" mac/build/Islet.app/Contents/MacOS/Islet
```

loads pages straight from the checkout; edit, then choose Reload from the menu bar item. With Safari's Develop
menu enabled, the wallpaper and settings pages show up there for inspection. `WALLPAPER_PROFILE_DIR=/some/dir`
keeps a test run's settings and log away from the real ones.

## Files

| Path | Contents |
| --- | --- |
| `Sources/main.swift` | Entry point, command-line flags, single instance |
| `Sources/AppDelegate.swift` | Menu bar item, settings messages, sharing |
| `Sources/Wallpaper.swift` | Desktop-level window, page messages, pause detection |
| `Sources/IconReader.swift` | Desktop icon rectangles from Finder |
| `Sources/SettingsWindow.swift` | Settings window |
| `Sources/WebHost.swift` | `app://` scheme, script bridge, offline rule |
| `Sources/Support.swift` | Paths, log, settings file, theme manifest, strings, login item |
| `web/` | Bridge shim and string overrides |
| `AppIcon.png` | This build's own icon |
| `TESTING.md` | Manual test checklist |
