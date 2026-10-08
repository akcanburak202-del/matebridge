#!/usr/bin/env bash
# Installs the client APK on the tablet without the user tapping the confirmation dialogs, then starts MateBridge.
#
# HarmonyOS shows up to two confirmations during `adb install`. This script taps ONLY these two buttons, matched
# by package + resource-id (never by text; see docs/NOTES.md 2026-10-01 01:35, a text match once installed
# unwanted store apps):
#   1. com.android.packageinstaller  android:id/button1                                   ("DEVAM ET")
#   2. com.huawei.appmarket          com.huawei.appmarket:id/hidden_card_install_button_continue  (bottom "YÜKLE")
# Nothing else on an AppGallery screen is ever tapped.
#
# Usage: scripts/install-apk.sh [--debug | path/to/app.apk]
#   default: the non-debuggable "daily" APK (T-301, decision 0037); --debug installs the debug APK (run-as, diagnostics).
#   Both are signed with the debug key, so either updates the other in place with `adb install -r -d`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/client-android/app/build/outputs/apk"
case "${1:-}" in
  --debug) APK="$OUT/debug/app-debug.apk" ;;
  "") APK="$OUT/daily/app-daily.apk" ;;
  *) APK="$1" ;;
esac
PKG="dev.matebridge.client"
ADB="${ADB:-$(command -v adb || echo "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb")}"
TIMEOUT_S="${INSTALL_TIMEOUT_S:-180}"

[ -f "$APK" ] || { echo "APK not found: $APK" >&2; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "no device (adb get-state failed)" >&2; exit 1; }
# Only the HUAWEI tablet: another Android device on the cable (e.g. the user's phone) must never get the APK.
brand="$("$ADB" shell getprop ro.product.brand | tr -d '\r')"
[ "$brand" = "HUAWEI" ] || { echo "connected device is not the HUAWEI tablet (brand=$brand); not installing" >&2; exit 1; }

before="$("$ADB" shell dumpsys package "$PKG" | sed -n 's/.*lastUpdateTime=//p' | head -1)"
log="$(mktemp -t mb-install)"
# -d: versionCode is the build minute (T-301), so a freshly built APK always installs over an older one. -d still lets a
# debuggable installed app take an older APK; a non-debuggable (daily) one refuses (rebuild instead). Never uninstall:
# that deletes the pairing keys.
"$ADB" install -r -d "$APK" >"$log" 2>&1 &
install_pid=$!

# Prints "x y" for the centre of the first allowed button on screen, or nothing.
find_button() {
  "$ADB" shell uiautomator dump /sdcard/mb-ui.xml >/dev/null 2>&1 || return 0
  "$ADB" exec-out cat /sdcard/mb-ui.xml 2>/dev/null | python3 -c '
import re, sys, xml.etree.ElementTree as ET
ALLOWED = {
    ("com.android.packageinstaller", "android:id/button1"),
    ("com.huawei.appmarket", "com.huawei.appmarket:id/hidden_card_install_button_continue"),
}
try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    sys.exit(0)
for n in root.iter("node"):
    if (n.get("package"), n.get("resource-id")) in ALLOWED and n.get("enabled") == "true":
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            print((x1 + x2) // 2, (y1 + y2) // 2, n.get("package"), n.get("resource-id"))
            break
'
}

start=$SECONDS
while kill -0 "$install_pid" 2>/dev/null; do
  if (( SECONDS - start > TIMEOUT_S )); then
    kill "$install_pid" 2>/dev/null || true
    echo "install timed out after ${TIMEOUT_S}s" >&2
    break
  fi
  # Installed already: the AppGallery page then shows "BİTTİ"; tapping it is optional, `am start` below covers it.
  now_ts="$("$ADB" shell dumpsys package "$PKG" | sed -n 's/.*lastUpdateTime=//p' | head -1)"
  if [ "$now_ts" != "$before" ]; then break; fi
  read -r x y pkg rid < <(find_button) || true
  if [ -n "${x:-}" ]; then
    echo "tap $pkg $rid at $x,$y"
    "$ADB" shell input tap "$x" "$y"
    sleep 2
  else
    sleep 1
  fi
  x=""
done
kill "$install_pid" 2>/dev/null || true  # done (or timed out): do not wait on the AppGallery page
wait "$install_pid" 2>/dev/null || true
cat "$log"
if grep -q INSTALL_FAILED_VERSION_DOWNGRADE "$log"; then
  echo "VERSION_DOWNGRADE: the installed app is non-debuggable (daily) and has a higher versionCode than this APK." >&2
  echo "versionCode is build-time minutes (T-301): rebuild the APK now (a fresh build is always newer). Do NOT uninstall: that deletes the pairing keys." >&2
fi
rm -f "$log"

after="$("$ADB" shell dumpsys package "$PKG" | sed -n 's/.*lastUpdateTime=//p' | head -1)"
if [ "$after" = "$before" ]; then
  echo "NOT installed (lastUpdateTime still $after)" >&2
  exit 1
fi
echo "installed: lastUpdateTime $before -> $after"
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
echo "started $PKG"
