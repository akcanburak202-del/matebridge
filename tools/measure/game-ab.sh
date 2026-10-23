#!/usr/bin/env bash
# Game-mode A/B recorder (T-364): one arm of one condition, tablet + Mac + host.log recorded at the same time.
# Read-only on both devices: it never installs, changes settings, or starts/stops either app, and opens no window.
# The setting under test is changed by the user in the tablet's settings panel BEFORE each run (recipe 5 in README.md).
#
# Usage: tools/measure/game-ab.sh LABEL --arm ARM --seconds N --out DIR [--proc "Game name"]...
#                                 [--expect KEY=VALUE]... [--content TEXT] [--runs N] [--no-tablet]
#   LABEL, ARM     letters, digits, . _ + - only (e.g. A1, bitrate30)
#   --seconds N    recording length (90-120 per the plan)
#   --out DIR      writes DIR/LABEL/ARM-K/ (K = how many times this ARM was recorded before, plus 1)
#   --proc NAME    Mac process whose CPU is tracked (the game); VTEncoderXPCService is always tracked.
#                  top shows 16 characters of a name; longer names are cut here.
#   --expect K=V   what the arm should have applied, checked against the logs (arm_check: MISMATCH when not):
#                  bitrate_kbps=30000  chroma=normal|sharp|full (or 420|sharp_nearest|packed444)  width=2240
#                  fps=60  transport=wifi|usb  size=2240x1472
#   --runs N       planned repeats of this arm (header run count; N >= 3 before any claim)
#   --no-tablet    skip the tablet part
# Writes only filtered (numeric) files: meta.txt tablet.txt tablet_ident.txt host.txt host_ident.txt mac.txt
# summary.txt. Afterwards: python3 tools/measure/game_ab.py summary DIR/LABEL
# Env: ADB, ANDROID_SERIAL (never printed), MB_HOST_LOG_DIR (default ~/Library/Logs/MateBridge),
#      MB_MAC_INTERVAL (macmon sample interval, default 5 s)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/tools/measure"
PKG="dev.matebridge.client"

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }

label="" arm="" seconds="" out="" content="" runs="" want_tablet=1
procs=() expects=()
while [ $# -gt 0 ]; do
  case $1 in
    --arm) arm=${2:?}; shift 2 ;;
    --seconds) seconds=${2:?}; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    --proc) procs+=("${2:?}"); shift 2 ;;
    --expect) expects+=("${2:?}"); shift 2 ;;
    --content) content=${2:?}; shift 2 ;;
    --runs) runs=${2:?}; shift 2 ;;
    --no-tablet) want_tablet=0; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "game-ab: unknown argument '$1'" >&2; usage ;;
    *) if [ -z "$label" ]; then label=$1; shift; else echo "game-ab: extra argument '$1'" >&2; usage; fi ;;
  esac
done
[ -n "$label" ] && [ -n "$arm" ] && [ -n "$seconds" ] && [ -n "$out" ] || { echo "game-ab: LABEL, --arm, --seconds, --out are required" >&2; usage; }
case $seconds in ''|*[!0-9]*|0) echo "game-ab: --seconds needs a positive whole number" >&2; exit 2 ;; esac
case $label$arm in *[!A-Za-z0-9._+-]*) echo "game-ab: LABEL and ARM may only hold letters, digits, . _ + -" >&2; exit 2 ;; esac
case "${runs:-1}" in *[!0-9]*) echo "game-ab: --runs needs a whole number" >&2; exit 2 ;; esac
for e in ${expects[@]+"${expects[@]}"}; do
  case $e in *=*) ;; *) echo "game-ab: --expect needs KEY=VALUE, got '$e'" >&2; exit 2 ;; esac
done

ADB="${ADB:-$(command -v adb || echo "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb")}"
LOGDIR="${MB_HOST_LOG_DIR:-$HOME/Library/Logs/MateBridge}"
HOSTLOG="$LOGDIR/host.log"
interval="${MB_MAC_INTERVAL:-5}"

# K = next repeat of this arm
mkdir -p "$out/$label" || exit 1
k=1
while [ -e "$out/$label/$arm-$k" ]; do k=$((k + 1)); done
dir="$out/$label/$arm-$k"
tmp="$(mktemp -d -t mb-gameab)"
lc_pid="" mac_pid="" f_pid=""
cleanup() {
  [ -n "$lc_pid" ] && kill "$lc_pid" 2>/dev/null
  [ -n "$mac_pid" ] && kill "$mac_pid" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
mkdir "$dir" || exit 1

say() { echo "game-ab: $*" >&2; }
filter() { python3 "$M/mblog.py" filter "$@"; }
: >"$tmp/tablet_ident" ; : >"$tmp/tablet_win" ; : >"$tmp/host_ident" ; : >"$tmp/host_win"

# --- tablet: one HUAWEI device only; the serial is never printed
tablet=0
if [ $want_tablet -eq 1 ]; then
  if [ ! -x "$ADB" ]; then
    say "adb not found ($ADB); tablet part skipped"
  else
    state="$("$ADB" get-state 2>&1 | tr -d '\r')"
    if [ "$state" != device ]; then
      case $state in
        *"more than one"*) say "more than one adb device: set ANDROID_SERIAL; tablet part skipped" ;;
        *) say "no adb device; tablet part skipped" ;;
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
  "$ADB" logcat -d -v epoch 2>/dev/null | filter --side tablet >"$tmp/tablet_ident"
fi

# --- host: identity from the log history (newest line wins), then the window slice by byte offsets
want_host=1
if [ -f "$HOSTLOG" ]; then
  for f in "$LOGDIR"/host.4.log "$LOGDIR"/host.3.log "$LOGDIR"/host.2.log "$LOGDIR"/host.1.log "$HOSTLOG"; do
    [ -f "$f" ] && grep -a -h -E ' ev=(app_start|profile|session_started|encoder_hw|chroma_config)( |$)' "$f"
  done | filter --side host >"$tmp/host_ident"
  host_off="$(stat -f %z "$HOSTLOG" 2>/dev/null || echo 0)"
else
  say "no host log at $HOSTLOG; host part skipped"
  want_host=0 host_off=0
fi
macos="$(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
host_instances="$(pgrep -x MateBridgeApp 2>/dev/null | wc -l | tr -d ' ')"

# --- Mac sampler (background) + tablet logcat (background), then wait
mac_args=(--interval "$interval" --count $(((seconds + interval - 1) / interval)) --proc VTEncoderXPCServ)
for pr in ${procs[@]+"${procs[@]}"}; do
  pr="${pr:0:16}"; pr="${pr%"${pr##*[! ]}"}"   # top cuts names at 16 characters
  mac_args+=(--proc "$pr")
done
MB_HOST_LOG_DIR="$LOGDIR" bash "$M/macmon.sh" "${mac_args[@]}" --out "$tmp/mac" &
mac_pid=$!
if [ $tablet -eq 1 ]; then
  mkfifo "$tmp/lc"
  "$ADB" logcat -v epoch -T 1 >"$tmp/lc" 2>/dev/null &
  lc_pid=$!
  filter --side tablet --skip-first 1 <"$tmp/lc" >"$tmp/tablet_win" &
  f_pid=$!
fi
say "recording $label $arm-$k for ${seconds}s (keep the game running; do not touch the settings)..."
sleep "$seconds"
if [ -n "$lc_pid" ]; then kill "$lc_pid" 2>/dev/null; wait "$lc_pid" 2>/dev/null; lc_pid=""; fi
[ -n "$f_pid" ] && wait "$f_pid" 2>/dev/null
wait "$mac_pid" 2>/dev/null; mac_pid=""
if [ $want_host -eq 1 ]; then
  now_size="$(stat -f %z "$HOSTLOG" 2>/dev/null || echo 0)"
  if [ "$now_size" -ge "$host_off" ]; then
    tail -c +$((host_off + 1)) "$HOSTLOG"
  else # rotated during the window: rest of the old file, then the new one
    [ -f "$LOGDIR/host.1.log" ] && tail -c +$((host_off + 1)) "$LOGDIR/host.1.log"
    cat "$HOSTLOG"
  fi | filter --side host >"$tmp/host_win"
fi

# --- keep only filtered files
exp_csv=""
for e in ${expects[@]+"${expects[@]}"}; do exp_csv="${exp_csv:+$exp_csv,}$e"; done
{
  echo "arm=$arm"
  echo "k=$k"
  echo "label=$label"
  echo "seconds=$seconds"
  echo "start_ep=$(($(date +%s) - seconds))"
  echo "runs=${runs:-}"
  echo "expect=$exp_csv"
  echo "content=$(printf '%s' "$content" | tr -d '\r\n')"
  echo "macos=$macos"
  echo "harmonyos=$harmonyos"
  echo "apk_version_code=$apk_vc"
  echo "host_instances=$host_instances"
  echo "tablet=$tablet"
  echo "host=$want_host"
} >"$dir/meta.txt"
cp "$tmp/tablet_ident" "$dir/tablet_ident.txt"
cp "$tmp/tablet_win" "$dir/tablet.txt"
cp "$tmp/host_ident" "$dir/host_ident.txt"
cp "$tmp/host_win" "$dir/host.txt"
cp "$tmp/mac" "$dir/mac.txt" 2>/dev/null || : >"$dir/mac.txt"

ab_args=(arm "$dir")
[ -n "$runs" ] && ab_args+=(--runs "$runs")
python3 "$M/game_ab.py" "${ab_args[@]}" | tee "$dir/summary.txt"
status=${PIPESTATUS[0]}
say "kept in $dir (filtered files only). All arms so far: python3 tools/measure/game_ab.py summary $out/$label"
exit "$status"
