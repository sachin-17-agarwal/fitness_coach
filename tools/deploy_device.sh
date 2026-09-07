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
#
# Exit codes: 0 installed, 2 no device found, anything else is the failing
# tool's own code. Output is plain so launchd's log stays readable.

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO/Vaux/Vaux.xcodeproj"
SCHEME="Vaux"
BUNDLE_ID="Sachin.Vaux2"
DERIVED="$REPO/build/DerivedData"
LAUNCH=0
WANT="${VAUX_DEVICE:-}"

for arg in "$@"; do
    case "$arg" in
        --launch) LAUNCH=1 ;;
        *) WANT="$arg" ;;
    esac
done

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ── Find the phone ──────────────────────────────────────────────────────────
# devicectl knows every phone this Mac has paired with; we want one that is
# reachable right now, matched by name or UDID when one was given.
DEVICES_JSON="$(mktemp)"
trap 'rm -f "$DEVICES_JSON"' EXIT
xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null 2>&1

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
    exit 2
fi
log "Device $UDID"

# ── Build ───────────────────────────────────────────────────────────────────
# -allowProvisioningUpdates lets xcodebuild renew the free profile itself,
# which is the whole point: a fresh signature every run.
log "Building $SCHEME"
xcodebuild \
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
xcrun devicectl device install app --device "$UDID" "$APP"

if [ "$LAUNCH" = 1 ]; then
    log "Launching $BUNDLE_ID"
    xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" || true
fi

log "Done — signature good for another seven days"
