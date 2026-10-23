#!/usr/bin/env bash
# Builds build/SSIN.app without Xcode (Command Line Tools are enough).
#   scripts/build-app.sh            release build
#   scripts/build-app.sh --install  also copy it to /Applications and launch it
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/SSIN.app"
IDENTITY="SSIN Local Signing"

echo "▸ Compiling (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/SSIN"

if [ ! -f Resources/AppIcon.icns ]; then
  echo "▸ Generating icon…"
  TMP="$(mktemp -d)"
  swift scripts/make-icon.swift "$TMP/icon.png" >/dev/null
  mkdir -p "$TMP/AppIcon.iconset"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$TMP"
fi

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SSIN"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the Screen Recording permission across rebuilds.
# Without it (ad-hoc signing) macOS asks for the permission again after every build.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "  (ad-hoc signing — run scripts/setup-signing.sh once to keep permissions across rebuilds)"
fi
if ! ERR="$(codesign --force --sign "$SIGN" --timestamp=none "$APP" 2>&1)"; then
  echo "  (signing with '$SIGN' failed: $ERR — falling back to ad-hoc)"
  SIGN="-"
  codesign --force --sign - --timestamp=none "$APP"
fi
if codesign -dr - "$APP" 2>&1 | grep -q "certificate leaf"; then
  KIND="stable ($IDENTITY) — permissions survive rebuilds"
else
  KIND="ad-hoc — permissions reset after each rebuild"
fi
echo "✓ Built $APP"
echo "  signature: $KIND"

if [ "${1:-}" = "--install" ]; then
  echo "▸ Installing to /Applications…"
  pkill -x SSIN 2>/dev/null || true
  rm -rf /Applications/SSIN.app
  cp -R "$APP" /Applications/
  open /Applications/SSIN.app
  echo "✓ Installed and launched"
fi
