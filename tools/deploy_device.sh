#!/bin/bash
# deploy_device.sh — build Vaux and install it on the iPhone in one command.
#
# Why this exists. The app is signed with a free Apple ID, and a free
# provisioning profile expires seven days after it is issued. A week without
# a fresh one and the app stops launching. This script builds and installs
# without Xcode open, so a launchd job (tools/com.vaux.deploy.plist) can keep
# the clock reset whether or not anything changed that week.
#
# Note that a plain build does NOT restart the clock: Xcode reuses a managed
# profile that is still valid, however close to expiry, and only issues a new
# one when the old has run out. So this script deletes the cached profiles
# for the app before building, which makes xcodebuild issue new ones dated
# today, and after the build it reads the expiry out of the installed app
# and prints it, so the log shows the seven days rather than assumes them.
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

# A failed run used to vanish into the launchd log, and the app simply
# stopped opening a few days later. Now every non-zero exit puts a macOS
# notification on screen once the last good install is old enough to matter,
# so the one thing that needs a human (a new Xcode, the phone unplugged) is
# seen the same day.
on_exit() {
    code=${1:-$?}
    [ "$code" -ne 0 ] || return 0
    age=""
    if [ -f "$STAMP" ]; then age=$(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 86400 )); fi
    if [ -z "$age" ] || [ "$age" -ge "$DUE_AFTER_DAYS" ]; then
        osascript -e "display notification \"Re-sign failed (exit $code)${age:+, last good install $age day(s) ago}. See ~/Library/Logs/vaux-deploy.log\" with title \"Vaux deploy\"" 2>/dev/null || true
    fi
}
trap on_exit EXIT

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
# Which Xcode. The project file is objectVersion 77 (Xcode 16 folder-synced
# groups), so an older xcodebuild rejects it as "damaged … didn't find
# classname for 'isa' key", and Xcode 14 and older have no devicectl at all.
# Both happened here: /Applications/Xcode.app was a stale copy while the
# Xcode actually used sat next to it. So: honour DEVELOPER_DIR, then
# xcode-select, but if that Xcode is too old, take the newest one installed.
MIN_XCODE=16
xcode_major() { "$1/usr/bin/xcodebuild" -version 2>/dev/null | awk 'NR==1 {print int($2)}'; }
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
CUR_MAJOR="$(xcode_major "$DEV_DIR")"
# Every Xcode on the Mac, wherever it was unzipped: the two usual folders,
# then Spotlight by bundle id, which also finds a copy left in Downloads.
all_xcodes() {
    { ls -d /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app 2>/dev/null
      mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null
      # Spotlight misses a copy on a volume or folder it does not index, so
      # also walk the places an Xcode gets unzipped into.
      find "$HOME/Downloads" "$HOME/Desktop" "$HOME" /Volumes -maxdepth 2 -type d -name 'Xcode*.app' 2>/dev/null; } | sort -u
}
if [ -z "$CUR_MAJOR" ] || [ "$CUR_MAJOR" -lt "$MIN_XCODE" ]; then
    BEST=""; BEST_MAJOR=0; FOUND=""
    while IFS= read -r app; do
        [ -n "$app" ] && [ -d "$app" ] || continue
        v="$(xcode_major "$app/Contents/Developer")"
        [ -n "$v" ] || continue
        FOUND="$FOUND
    $app  (Xcode $v)"
        if [ "$v" -gt "$BEST_MAJOR" ]; then BEST_MAJOR="$v"; BEST="$app/Contents/Developer"; fi
    done <<< "$(all_xcodes)"
    if [ "$BEST_MAJOR" -ge "$MIN_XCODE" ]; then
        log "Xcode at ${DEV_DIR:-<none>} is version ${CUR_MAJOR:-?}; using $BEST instead"
        DEV_DIR="$BEST"
    else
        log "This project needs Xcode $MIN_XCODE or newer. Xcode found on this Mac:${FOUND:-  none}"
        log "If a newer Xcode is somewhere else on this Mac, point the script at it:"
        log "    DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer $0 $*"
        log "or make it the default:  sudo xcode-select -s /path/to/Xcode.app"
        log "To find it:  find / -maxdepth 4 -type d -name 'Xcode*.app' 2>/dev/null"
        log "If the Xcode you build the app with is on another computer, the re-sign job has to run there."
        exit 3
    fi
fi
export DEVELOPER_DIR="$DEV_DIR"
XCODEBUILD="$DEV_DIR/usr/bin/xcodebuild"
log "Using $("$XCODEBUILD" -version | head -1) at $DEV_DIR"
# devicectl ships inside Xcode 15 and newer; the CoreDevice framework under
# /Library/Developer carries a copy too once Xcode's first-launch components
# are installed. Try the selected Xcode first, then those.
DEVICECTL=""
for candidate in \
    "$DEV_DIR/usr/bin/devicectl" \
    /Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl \
    "$(xcrun --find devicectl 2>/dev/null || true)"; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then DEVICECTL="$candidate"; break; fi
done
if [ -z "$DEVICECTL" ]; then
    log "devicectl not found. It is installed by Xcode's first-launch components (CoreDevice)."
    log "Run:  sudo xcodebuild -runFirstLaunch    then try again."
    log "xcode-select -p says: $(xcode-select -p 2>&1)"
    exit 3
fi

log "Looking for the phone…"
DEVICES_JSON="$(mktemp)"
trap 'c=$?; rm -f "$DEVICES_JSON"; on_exit $c' EXIT
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
    log "No reachable iPhone${WANT:+ matching '$WANT'}."
    log "Devices this Mac knows about:"
    # The iOS version this Xcode ships developer services for: a phone on a
    # newer major (a beta, usually) is paired and even wired yet never gets a
    # tunnel, and devicectl reports it only as ddiServicesAvailable=false.
    SDK_IOS="$("$XCODEBUILD" -showsdks 2>/dev/null | awk '/iphoneos/ {sub("iphoneos","",$NF); print $NF; exit}')"
    python3 - "$DEVICES_JSON" "$SDK_IOS" "$("$XCODEBUILD" -version | head -1)" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
sdk_ios, xcode = sys.argv[2], sys.argv[3]
sdk_major = int(sdk_ios.split(".")[0]) if sdk_ios[:1].isdigit() else None
too_new = []
for d in data.get("result", {}).get("devices", []):
    hw, props, conn = d.get("hardwareProperties", {}), d.get("deviceProperties", {}), d.get("connectionProperties", {})
    os_v = props.get("osVersionNumber", "?")
    beta = " beta" if props.get("releaseType") == "Beta" else ""
    print(f"  {props.get('name','?').strip()} · {hw.get('platform','?')} {os_v}{beta} · {conn.get('transportType','?')} · "
          f"{conn.get('pairingState','?')} · tunnel {conn.get('tunnelState','?')} · "
          f"developer services {'yes' if props.get('ddiServicesAvailable') else 'no'} · {hw.get('udid','')}")
    if hw.get("platform") == "iOS" and not props.get("ddiServicesAvailable") and sdk_major:
        try:
            if int(os_v.split(".")[0]) > sdk_major:
                too_new.append((props.get("name", "?").strip(), os_v + beta))
        except ValueError:
            pass
if too_new:
    for name, os_v in too_new:
        print(f"{name} runs iOS {os_v}, but {xcode} only carries developer services up to iOS {sdk_ios}.")
    print("No cable, Wi-Fi or pairing step fixes that. Install an Xcode whose iOS SDK is at least the phone's major")
    print("version (a beta phone needs the matching beta Xcode) into /Applications; this script picks the newest one.")
else:
    print("Is the phone on the same Wi-Fi or plugged in, unlocked once recently, and paired with this Mac?")
PY
    exit 2
fi
log "Device $UDID"

# ── Force a fresh profile ───────────────────────────────────────────────────
# Managed profiles are cached here (Xcode 16+ first, older Xcode second).
# Removing the ones for this app and its extension makes the build below
# request new ones; nothing else is touched and Xcode recreates them on
# demand. The application-identifier inside a profile is TEAMID.bundle, so
# a fixed-string match on ".Sachin.Vaux2" catches the widget's too.
REMOVED=0; DAYS_LEFT=""; EXPIRY=""
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
           "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision; do
        [ -f "$f" ] || continue
        if security cms -D -i "$f" 2>/dev/null | grep -qF ".$BUNDLE_ID"; then
            rm -f "$f" && REMOVED=$((REMOVED + 1))
        fi
    done
done
log "Cleared $REMOVED cached profile(s) for $BUNDLE_ID so new seven-day ones are issued"

# ── Build ───────────────────────────────────────────────────────────────────
# -allowProvisioningUpdates lets xcodebuild talk to Apple and issue the
# profiles it now finds missing.
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

# What did we actually sign with? Read the expiry out of the built app.
EXPIRY="$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null \
          | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)"
if [ -n "$EXPIRY" ]; then
    EXP_S="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$EXPIRY" +%s 2>/dev/null || echo 0)"
    DAYS_LEFT=$(( (EXP_S - $(date +%s)) / 86400 ))
    log "Profile expires $EXPIRY ($DAYS_LEFT days)"
    if [ "$EXP_S" -gt 0 ] && [ "$DAYS_LEFT" -lt 6 ]; then
        log "WARNING: the profile was reused, not renewed. Open Xcode once, sign out and back in under Settings > Accounts, and run this again."
    fi
else
    log "Could not read the profile expiry from $APP"
fi

# ── Install ─────────────────────────────────────────────────────────────────
log "Installing"
"$DEVICECTL" device install app --device "$UDID" "$APP"

if [ "$LAUNCH" = 1 ]; then
    log "Launching $BUNDLE_ID"
    "$DEVICECTL" device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" || true
fi

mkdir -p "$STAMP_DIR" && touch "$STAMP"
log "Done${DAYS_LEFT:+ — app runs until $EXPIRY}"
