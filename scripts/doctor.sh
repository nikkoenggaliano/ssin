#!/usr/bin/env bash
# Health check for an SSIN install: signature, quarantine, running copies, conflicting apps.
#   scripts/doctor.sh                  checks /Applications/SSIN.app
#   scripts/doctor.sh build/SSIN.app   checks another copy
APP="${1:-/Applications/SSIN.app}"
IDENTITY="SSIN Local Signing"
ok() { echo "  ✓ $*"; }
warn() { echo "  ! $*"; }
bad() { echo "  ✗ $*"; }

echo "SSIN doctor — $APP"

if [ ! -d "$APP" ]; then
  bad "app not found → run: scripts/build-app.sh --install"
  exit 1
fi
ok "app found"

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  ok "signing identity '$IDENTITY' is in your keychain"
else
  warn "no signing identity → run scripts/setup-signing.sh once, then rebuild"
fi

DR="$(codesign -dr - "$APP" 2>&1 | grep designated)"
case "$DR" in
  *"certificate leaf"*) ok "stable signature — Screen Recording permission survives rebuilds" ;;
  *cdhash*) warn "ad-hoc signature — macOS forgets the permission after every rebuild" ;;
  *) bad "app is not signed → rebuild with scripts/build-app.sh" ;;
esac

if codesign --verify --strict "$APP" 2>/dev/null; then
  ok "signature is valid"
else
  bad "signature is broken (app modified after signing?) → rebuild"
fi

if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
  warn "app is quarantined → xattr -dr com.apple.quarantine \"$APP\""
else
  ok "not quarantined"
fi

COUNT=$(pgrep -x SSIN | wc -l | tr -d ' ')
case "$COUNT" in
  0) warn "SSIN is not running → open \"$APP\"" ;;
  1) ok "SSIN is running (pid $(pgrep -x SSIN))" ;;
  *) warn "$COUNT copies of SSIN are running → quit all, open only $APP" ;;
esac
for pid in $(pgrep -x SSIN); do
  path="$(ps -p "$pid" -o comm=)"
  case "$path" in "$APP"/*) ;; *) warn "a different copy is running: $path" ;; esac
done

for other in "Shottr" "CleanShot X" "Xnapper"; do
  if pgrep -xq "$other"; then warn "$other is running — its shortcuts can steal SSIN's (quit it)"; fi
done

case "$(sfltool dumpbtm 2>/dev/null | grep -B4 -A2 'Identifier: 2.dev.ssin.app' | grep -E 'Disposition|URL' | tr '\n' ' ')" in
  *"[enabled"*"$APP"*) ok "launch at login is on" ;;
  *"[enabled"*) warn "launch at login points at another copy → turn it off and on again in SSIN → Settings" ;;
  *) warn "launch at login is off → SSIN → Settings → General → Launch at login" ;;
esac

# The project's own build/ output is expected; any other copy can confuse Launch at Login.
PROJECT_BUILD="$(cd "$(dirname "$0")/.." && pwd)/build/SSIN.app"
COPIES="$(mdfind "kMDItemCFBundleIdentifier == 'dev.ssin.app'" 2>/dev/null | grep -v '/\.build/' | grep -vxF "$PROJECT_BUILD" | grep -vxF "$APP")"
if [ -n "$COPIES" ]; then
  warn "other SSIN.app copies exist (can confuse Launch at Login):"
  printf '%s\n' "$COPIES" | sed 's/^/      /'
fi

echo
echo "Permission status: open SSIN → Settings → General → \"Screen Recording permission\" should say Granted."
