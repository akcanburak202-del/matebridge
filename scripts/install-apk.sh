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
# Usage: scripts/install-apk.sh [path/to/app.apk]   (default: the debug APK from ./scripts/check.sh)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="${1:-$ROOT/client-android/app/build/outputs/apk/debug/app-debug.apk}"
PKG="dev.matebridge.client"
ADB="${ADB:-$(command -v adb || echo "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb")}"
TIMEOUT_S="${INSTALL_TIMEOUT_S:-180}"

[ -f "$APK" ] || { echo "APK not found: $APK" >&2; exit 1; }
"$ADB" get-state >/dev/null 2>&1 || { echo "no device (adb get-state failed)" >&2; exit 1; }

before="$("$ADB" shell dumpsys package "$PKG" | sed -n 's/.*lastUpdateTime=//p' | head -1)"
log="$(mktemp -t mb-install)"
"$ADB" install -r "$APK" >"$log" 2>&1 &
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
wait "$install_pid" 2>/dev/null || true
cat "$log"; rm -f "$log"

after="$("$ADB" shell dumpsys package "$PKG" | sed -n 's/.*lastUpdateTime=//p' | head -1)"
if [ "$after" = "$before" ]; then
  echo "NOT installed (lastUpdateTime still $after)" >&2
  exit 1
fi
echo "installed: lastUpdateTime $before -> $after"
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
echo "started $PKG"
