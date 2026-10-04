#!/usr/bin/env bash
# One-command device smoke (T-173): names the build and setup, then records a numeric stats window.
# Read-only on both devices: it never installs, changes settings, or starts/stops either app. Run it while a
# session is streaming. Device checks run one at a time (CLAUDE.md).
#
# Usage: scripts/device-smoke.sh [--seconds 60] [--content TEXT] [--run K --runs N] [--out DIR]
#                                [--header-only] [--no-tablet] [--no-host]
#   --seconds S     stats window length (default 60)
#   --content TEXT  what is on screen / being done; goes into the result header
#   --run/--runs    run k of n for this condition (n >= 3 before quoting any number)
#   --out DIR       also keep the filtered (numeric-only) inputs and the report in DIR
#   --header-only   print the result header and build identity, skip the stats window
# Env: ADB (adb path), ANDROID_SERIAL (pick a device; never printed), MB_HOST_LOG_DIR (default ~/Library/Logs/MateBridge)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$ROOT/tools/measure"
PKG="dev.matebridge.client"

usage() { sed -n '6,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

seconds=60 content="" run="" runs="" out="" header_only=0 want_tablet=1 want_host=1
while [ $# -gt 0 ]; do
  case $1 in
    --seconds) seconds=${2:?}; shift 2 ;;
    --content) content=${2:?}; shift 2 ;;
    --run) run=${2:?}; shift 2 ;;
    --runs) runs=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --header-only) header_only=1; shift ;;
    --no-tablet) want_tablet=0; shift ;;
    --no-host) want_host=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "device-smoke: unknown argument '$1'" >&2; usage ;;
  esac
done
case $seconds in ''|*[!0-9]*) echo "device-smoke: --seconds needs a whole number" >&2; exit 2 ;; esac

ADB="${ADB:-$(command -v adb || echo "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb")}"
LOGDIR="${MB_HOST_LOG_DIR:-$HOME/Library/Logs/MateBridge}"
HOSTLOG="$LOGDIR/host.log"
tmp="$(mktemp -d -t mb-smoke)"
lc_pid=""
cleanup() {
  [ -n "$lc_pid" ] && kill "$lc_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
: >"$tmp/host_ident" ; : >"$tmp/tablet_ident" ; : >"$tmp/host_win" ; : >"$tmp/tablet_win"

say() { echo "device-smoke: $*" >&2; }
filter() { python3 "$M/mblog.py" filter "$@"; }

# --- tablet: one HUAWEI device only (another phone on the cable is refused); the serial is never printed
tablet=0
if [ $want_tablet -eq 1 ]; then
  if [ ! -x "$ADB" ]; then
    say "adb not found ($ADB); tablet part skipped"
  else
    state="$("$ADB" get-state 2>&1 | tr -d '\r')"
    if [ "$state" != device ]; then
      case $state in
        *"more than one"*) say "more than one adb device: set ANDROID_SERIAL; tablet part skipped" ;;
        *) say "no adb device (get-state: not 'device'); tablet part skipped" ;;
      esac
    else
      brand="$("$ADB" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
      if [ "$brand" = HUAWEI ]; then tablet=1; else say "adb device is not the HUAWEI tablet; tablet part skipped"; fi
    fi
  fi
fi

harmonyos="" apk_vc=""
if [ $tablet -eq 1 ]; then
  harmonyos="$("$ADB" shell getprop ro.build.display.id 2>/dev/null | tr -d '\r' | tr -c 'A-Za-z0-9._()\n-' '_')"
  apk_vc="$("$ADB" shell dumpsys package "$PKG" 2>/dev/null | grep -m1 -o 'versionCode=[0-9]*' | cut -d= -f2)"
  # Identity lines still in the logcat ring (app_start, profile, codec_start, stream_config), filtered in the pipe.
  "$ADB" logcat -d -v epoch 2>/dev/null | filter --side tablet >"$tmp/tablet_ident"
fi

macos="$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
host_instances="$(pgrep -x MateBridgeApp 2>/dev/null | wc -l | tr -d ' ')"
if [ $want_host -eq 1 ]; then
  if [ -f "$HOSTLOG" ]; then
    # Oldest rotated file first, so the newest app_start/profile wins.
    for f in "$LOGDIR"/host.4.log "$LOGDIR"/host.3.log "$LOGDIR"/host.2.log "$LOGDIR"/host.1.log "$HOSTLOG"; do
      [ -f "$f" ] && grep -h -E ' ev=(app_start|profile|session_started|encoder_hw)( |$)' "$f"
    done | filter --side host >"$tmp/host_ident"
  else
    say "no host log at $HOSTLOG; host part skipped"
    want_host=0
  fi
fi

if [ $header_only -eq 0 ]; then
  host_off=0
  [ $want_host -eq 1 ] && host_off="$(stat -f %z "$HOSTLOG" 2>/dev/null || echo 0)"
  f_pid=""
  if [ $tablet -eq 1 ]; then
    mkfifo "$tmp/lc"
    "$ADB" logcat -v epoch -T 1 >"$tmp/lc" 2>/dev/null &
    lc_pid=$!
    filter --side tablet --skip-first 1 <"$tmp/lc" >"$tmp/tablet_win" &
    f_pid=$!
  fi
  say "collecting ${seconds}s of stats (keep the session streaming)..."
  sleep "$seconds"
  if [ -n "$lc_pid" ]; then kill "$lc_pid" 2>/dev/null; wait "$lc_pid" 2>/dev/null; lc_pid=""; fi
  [ -n "$f_pid" ] && wait "$f_pid" 2>/dev/null
  if [ $want_host -eq 1 ]; then
    now_size="$(stat -f %z "$HOSTLOG" 2>/dev/null || echo 0)"
    if [ "$now_size" -ge "$host_off" ]; then
      tail -c +$((host_off + 1)) "$HOSTLOG"
    else # rotated during the window: rest of the old file, then the new one
      [ -f "$LOGDIR/host.1.log" ] && tail -c +$((host_off + 1)) "$LOGDIR/host.1.log"
      cat "$HOSTLOG"
    fi | filter --side host >"$tmp/host_win"
  fi
fi

args=(--host-ident "$tmp/host_ident" --tablet-ident "$tmp/tablet_ident" --host-win "$tmp/host_win"
      --tablet-win "$tmp/tablet_win" --seconds "$seconds" --macos "$macos" --host-instances "$host_instances")
[ -n "$harmonyos" ] && args+=(--harmonyos "$harmonyos")
[ -n "$apk_vc" ] && args+=(--apk-version-code "$apk_vc")
[ -n "$content" ] && args+=(--content "$content")
[ -n "$run" ] && args+=(--run "$run")
[ -n "$runs" ] && args+=(--runs "$runs")
[ $header_only -eq 1 ] && args+=(--header-only)
python3 "$M/smoke.py" "${args[@]}" | tee "$tmp/report.txt"
status=${PIPESTATUS[0]}

if [ -n "$out" ]; then
  mkdir -p "$out"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  for f in host_ident tablet_ident host_win tablet_win report; do
    src="$tmp/$f"; [ "$f" = report ] && src="$tmp/report.txt"
    cp "$src" "$out/smoke-$stamp-$f.txt"
  done
  say "filtered inputs and report kept in $out (smoke-$stamp-*)"
fi
exit "$status"
