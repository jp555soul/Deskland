# Testing the macOS host

The web side (bridge shim, message protocol, string overrides) has been exercised against `flat.html`,
`meadow.html` and `settings.html`. The Swift host builds with no warnings on Apple Silicon. The checks
below are the ones that need a person at a Mac.

## Build and watch the log

```sh
mac/build.sh run
tail -f ~/Library/Application\ Support/Islet/host.log
```

Expected in the log, in order: `start Islet …`, `wallpaper window up …`, `page ready: flat.html`, `settings opened`.
If `page ready` never appears the page did not reach the host: check for a "host-shim.js is missing" line and
inspect the page from Safari → Develop → Islet.

## Checks

1. The beach scene replaces the wallpaper on the primary display, behind the desktop icons, and clicks on the
   desktop still reach Finder.
2. A menu bar item appears; Settings opens and shows the theme grid with a live preview.
3. Switching to Meadow in Settings changes the desktop.
4. After allowing the app under System Settings → Privacy & Security → Accessibility, the log shows

   ```
   Accessibility access granted, reading desktop icons
   Finder desktop: N elements, roles AXImage
   icons changed: N, visible=true, first=x,y WxH
   ```

   and sand (or meadow clearings) forms under the icons and follows one when it is dragged.
5. Zoom a window to fill the screen: the log shows `desktop covered by <app>` then `paused`; un-zoom: `running`.
6. Settings → Share image: a PNG lands in `~/Pictures/Islet` and on the clipboard.
7. Settings → Share video: an MP4 lands in `~/Pictures/Islet` and plays in the dialog (depends on WebKit's `MediaRecorder`).
8. Settings → Start at login: `~/Library/LaunchAgents/dev.islet.Islet.plist` appears and disappears with the switch.
9. `mac/build/Islet.app/Contents/MacOS/Islet --exit` quits the running copy and the normal wallpaper is back.

## If icon tracking is off

`IconReader.swift` assumes Finder exposes the desktop as application → `AXScrollArea` → `AXGroup` → one `AXImage`
per icon, with frames in global points measured from the top-left of the primary display.

- `icons changed: 0` with icons on the desktop, or a roles line without `AXImage`: the hierarchy differs on that
  macOS version. Inspect Finder with Accessibility Inspector and adjust `findContainer` and the role filter.
- Islands under the pictures but not the labels: the reported frame excludes the label; extend each rect downward
  in `IconReader.read()`.
- Islands offset from the icons: check the coordinate conversion in `WallpaperController.pushIcons`.
