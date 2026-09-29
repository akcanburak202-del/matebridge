#!/usr/bin/env bash
# USB mode: forward the tablet's 127.0.0.1:47001/47002 to the Mac's MateBridge listeners via adb reverse.
# Usage: scripts/usb-mode.sh [on|off|status]   (default: on)
set -uo pipefail

PORTS=(47001 47002)
cmd=${1:-on}

ADB=$(command -v adb || true)
for cand in "${ANDROID_HOME:-}/platform-tools/adb" "$HOME/Library/Android/sdk/platform-tools/adb"; do
  if [ -z "$ADB" ] && [ -x "$cand" ]; then ADB=$cand; fi
done
if [ -z "$ADB" ]; then
  echo "adb not found. Install Android platform-tools or set ANDROID_HOME." >&2
  exit 1
fi

# The adb server occasionally fails to start; retry a few times.
adb_retry() {
  local i out
  for i in 1 2 3 4; do
    "$ADB" start-server >/dev/null 2>&1 || true
    # Keep only the command's own output; the server prints "daemon started" lines we must not parse.
    if out=$("$ADB" "$@" 2>&1); then printf '%s\n' "$out" | grep -v '^\* daemon'; return 0; fi
    case "$out" in
      *"no devices"*|*"unauthorized"*|*"offline"*|*"not found"*) printf '%s\n' "$out" >&2; return 2 ;;
    esac
    sleep 1
  done
  printf '%s\n' "$out" >&2
  return 1
}

require_device() {
  local state
  state=$(adb_retry get-state 2>/dev/null) || {
    echo "No adb device found. Connect the tablet by USB and enable USB debugging (accept the prompt on the tablet)." >&2
    exit 1
  }
  if [ "$state" != "device" ]; then echo "Device state is '$state', expected 'device'." >&2; exit 1; fi
}

case "$cmd" in
  on)
    require_device
    for p in "${PORTS[@]}"; do
      adb_retry reverse "tcp:$p" "tcp:$p" >/dev/null || { echo "adb reverse failed for port $p" >&2; exit 1; }
    done
    echo "USB mode on: tablet 127.0.0.1:${PORTS[0]} -> Mac (video ${PORTS[1]})."
    ;;
  off)
    require_device
    for p in "${PORTS[@]}"; do adb_retry reverse --remove "tcp:$p" >/dev/null 2>&1 || true; done
    echo "USB mode off."
    ;;
  status)
    require_device
    adb_retry reverse --list
    ;;
  *)
    echo "Usage: $0 [on|off|status]" >&2
    exit 2
    ;;
esac
