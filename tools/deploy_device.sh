#!/bin/bash
# deploy_device.sh — build Vaux and install it on the iPhone in one command.
#
# Why this exists. The app is signed with a free Apple ID, and a free
# provisioning profile expires seven days after the build. Every Run from
# Xcode restarts that clock; a week without a build lets it run out and the
# app stops launching. This script is the Run button without Xcode open, so
# a weekly launchd job (tools/com.vaux.deploy.plist) can restart the clock
# whether or not anything changed that week.
#
# One-time setup on the Mac:
#   1. Xcode → Settings → Accounts: the Apple ID is signed in.
#   2. Plug the phone in once, trust the Mac, and in Xcode's Devices window
#      tick "Connect via network". After that no cable is needed while the
#      phone and Mac share a Wi-Fi network.
#   3. chmod +x tools/deploy_device.sh
#
# Usage:
#   tools/deploy_device.sh                 # first connected iPhone
#   tools/deploy_device.sh "Sachin's iPhone"
#   VAUX_DEVICE=00008140-000C78882E01801C tools/deploy_device.sh
#   tools/deploy_device.sh --launch        # also open the app afterwards
#   tools/deploy_device.sh --only-if-due   # skip if re-signed < 3 days ago
#
# --only-if-due is what the launchd job passes. The job fires twice a day
# rather than once a week, because the phone is not always on the home
# Wi-Fi when a single slot comes round; with the stamp file below, the first
# firing that finds the phone re-signs, and every other firing that week is
# a no-op. A missed slot costs nothing.
#
# Exit codes: 0 installed (or not due), 2 no device found, anything else is
# the failing tool's own code. Output is plain so launchd's log stays
# readable.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Vaux/Vaux.xcodeproj"
SCHEME="Vaux"
BUNDLE_ID="Sachin.Vaux2"
DERIVED="$REPO/build/DerivedData"
LAUNCH=0
ONLY_IF_DUE=0
WANT="${VAUX_DEVICE:-}"
STAMP_DIR="$HOME/Library/Application Support/vaux-deploy"
STAMP="$STAMP_DIR/last-success"
# Re-sign once the last good install is this old. The profile lasts seven
# days; three leaves four days of slots for the phone to be home in.
DUE_AFTER_DAYS=3

for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        --only-if-due) ONLY_IF_DUE=1 ;;
        *) WANT="$arg" ;;
    esac
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [ "$ONLY_IF_DUE" = 1 ] && [ -f "$STAMP" ]; then
    AGE_DAYS=$(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 86400 ))
    if [ "$AGE_DAYS" -lt "$DUE_AFTER_DAYS" ]; then
        log "Not due: last re-signed $AGE_DAYS day(s) ago"
        exit 0
    fi
fi

# ── Find the phone ──────────────────────────────────────────────────────────
# devicectl knows every phone this Mac has paired with; we want one that is
# reachable right now, matched by name or UDID when one was given.
# devicectl and xcodebuild by PATH inside the selected Xcode, not through
# the xcrun lookup, which failed here with "unable to find utility devicectl"
# while the binary sat exactly where Xcode puts it.
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || echo /Applications/Xcode.app/Contents/Developer)}"
DEVICECTL="$DEV_DIR/usr/bin/devicectl"
XCODEBUILD="$DEV_DIR/usr/bin/xcodebuild"
if [ ! -x "$DEVICECTL" ]; then
    log "devicectl not found at $DEVICECTL."
    log "xcode-select -p says: $(xcode-select -p 2>&1)"
    log "Xcodes installed: $(ls -d /Applications/Xcode*.app 2>/dev/null | tr '\n' ' ')"
    log "Point the command line at a full Xcode: sudo xcode-select -s /Applications/Xcode.app"
    exit 3
fi

log "Looking for the phone…"
DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
if ! "$DEVICECTL" list devices --json-output "$DEVICES_JSON"; then
    log "devicectl failed to list devices."
    exit 3
fi
if [ ! -s "$DEVICES_JSON" ]; then
    log "devicectl returned no device list."
    exit 3
fi

UDID="$(python3 - "$DEVICES_JSON" "$WANT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
want = sys.argv[2].strip().lower()
for d in data.get("result", {}).get("devices", []):
    hw = d.get("hardwareProperties", {})
    props = d.get("deviceProperties", {})
    conn = d.get("connectionProperties", {})
    if hw.get("platform") != "iOS":
        continue
    if conn.get("tunnelState") not in ("connected", "available"):
        continue
    name = (props.get("name") or "").lower()
    udid = hw.get("udid") or ""
    if want and want not in (name, udid.lower()):
        continue
    print(udid)
    break
PY
)"

if [ -z "$UDID" ]; then
    log "No reachable iPhone${WANT:+ matching '$WANT'}. Is it on the same Wi-Fi, unlocked once recently, and paired with this Mac?"
    log "Devices this Mac knows about:"
    python3 - "$DEVICES_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
for d in data.get("result", {}).get("devices", []):
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    print(f"  {props.get('name','?')} · {hw.get('platform','?')} · {conn.get('tunnelState','?')} · {hw.get('udid','')}")
PY
    exit 2
fi
log "Device $UDID"

# ── Build ───────────────────────────────────────────────────────────────────
# -allowProvisioningUpdates lets xcodebuild renew the free profile itself,
# which is the whole point: a fresh signature every run.
log "Building $SCHEME"
"$XCODEBUILD" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination "id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    -quiet \
    build

APP="$DERIVED/Build/Products/Debug-iphoneos/$SCHEME.app"
if [ ! -d "$APP" ]; then
    log "Build finished but $APP is missing"
    exit 3
fi

# ── Install ─────────────────────────────────────────────────────────────────
log "Installing"
"$DEVICECTL" device install app --device "$UDID" "$APP"

if [ "$LAUNCH" = 1 ]; then
    log "Launching $BUNDLE_ID"
    "$DEVICECTL" device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" || true
fi

mkdir -p "$STAMP_DIR" && touch "$STAMP"
log "Done — signature good for another seven days"
