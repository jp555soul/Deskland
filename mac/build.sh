#!/bin/bash
# Builds the macOS app with the Swift compiler from Xcode's Command Line Tools — no Xcode project.
#   mac/build.sh            build mac/build/<name>.app
#   mac/build.sh run        build, then start it (quitting a running copy first)
# Overrides: APP_NAME, BUNDLE_ID, MIN_OS, ARCHS="arm64 x86_64", SIGN_ID="Apple Development: …"
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Islet}"
BUNDLE_ID="${BUNDLE_ID:-dev.islet.Islet}"
MIN_OS="${MIN_OS:-12.0}"
ARCHS="${ARCHS:-$(uname -m)}"
VERSION="$(sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([0-9.]+)".*/\1/' "$ROOT/tools/version.json")"
OUT="$ROOT/mac/build"
APP="$OUT/$APP_NAME.app"

command -v swiftc >/dev/null || { echo "swiftc not found. Install the Command Line Tools: xcode-select --install" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tools/version.json has no usable version" >&2; exit 1; }

# A copy running from the build folder would lose its files mid-flight: quit it first, restart it after.
RESTART=0
if [ -x "$APP/Contents/MacOS/$APP_NAME" ] && pgrep -f "$APP/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
  "$APP/Contents/MacOS/$APP_NAME" --exit || true
  sleep 1
  RESTART=1
fi

mkdir -p "$OUT"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- compile -------------------------------------------------------------------------------
BINS=()
for arch in $ARCHS; do
  echo "Compiling ($arch)…"
  swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_OS" \
    -o "$OUT/$APP_NAME-$arch" "$ROOT"/mac/Sources/*.swift
  BINS+=("$OUT/$APP_NAME-$arch")
done
if [ "${#BINS[@]}" -gt 1 ]; then
  lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  cp "${BINS[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi

# --- resources -----------------------------------------------------------------------------
# The theme pages are used as they are upstream; Mac differences live in mac/web.
cp -R "$ROOT/prototype" "$APP/Contents/Resources/prototype"
rm -f "$APP/Contents/Resources/prototype/serve.mjs"
cp -R "$ROOT/mac/web" "$APP/Contents/Resources/mac-web"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/TRADEMARKS.md" "$APP/Contents/Resources/"

ICONSET="$OUT/AppIcon.iconset"
rm -rf "${ICONSET:?}"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/mac/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ROOT/mac/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>NSHumanReadableCopyright</key><string>Based on Deskland Preview, © 2026 Deskland authors. GPL-3.0.</string>
</dict>
</plist>
PLIST

# --- sign ----------------------------------------------------------------------------------
# macOS ties the Accessibility grant to the code signature. Ad-hoc signatures change on every
# build, so the grant has to be re-added each time; signing with a real identity keeps it.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -nE 's/.*"(Apple Development: [^"]+)".*/\1/p' | head -n 1 || true)"
fi
SIGN_ID="${SIGN_ID:--}"
if [ "$SIGN_ID" = "-" ]; then echo "Signing ad hoc (set SIGN_ID to keep the Accessibility grant across builds)"; else echo "Signing as $SIGN_ID"; fi
if ! codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1; then
  echo "Could not sign as $SIGN_ID, signing ad hoc instead"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null
fi

echo "Built $APP ($VERSION, $ARCHS)"

if [ "${1:-}" = "run" ] || [ "$RESTART" = 1 ]; then
  open "$APP"
fi
