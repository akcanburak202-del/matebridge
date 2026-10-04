#!/usr/bin/env bash
# Tablet soak sampler control (T-173, T-194). Runs tools/measure/mbmon.sh --soak ON the tablet, detached from adb,
# so cable pulls and Wi-Fi periods do not stop it. It never installs an app, changes a setting, or starts/stops
# MateBridge; it only copies the sampler script to /data/local/tmp.
#
# Usage: tools/soak/tablet-soak.sh start [--interval S] [--seconds N]   # default 60 s, until stopped
#        tools/soak/tablet-soak.sh status                                # sample count and the last sample
#        tools/soak/tablet-soak.sh stop
#        tools/soak/tablet-soak.sh pull DIR [--keep]                     # copy numeric samples + event names to DIR
# Env: ADB (adb path), ANDROID_SERIAL (pick a device; never printed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
M="$HERE/../measure"
ADB="${ADB:-$(command -v adb || echo "${ANDROID_HOME:-$HOME/Library/Android/sdk}/platform-tools/adb")}"
D=/data/local/tmp
SAMPLES=$D/mbsoak.txt
EVENTS=$D/mbsoak_events.txt

usage() { sed -n '6,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }
die() { echo "tablet-soak: $*" >&2; exit 1; }

device() {
  [ -x "$ADB" ] || die "adb not found ($ADB)"
  local state brand
  state="$("$ADB" get-state 2>&1 | tr -d '\r')"
  case $state in
    device) ;;
    *"more than one"*) die "more than one adb device: set ANDROID_SERIAL" ;;
    *) die "no adb device" ;;
  esac
  brand="$("$ADB" shell getprop ro.product.brand 2>/dev/null | tr -d '\r')"
  [ "$brand" = HUAWEI ] || die "adb device is not the HUAWEI tablet"
}

# The bracket keeps the pattern from matching the adb shell's own command line.
running() { "$ADB" shell "pgrep -f 'mbmon[.]sh --soak' >/dev/null && echo yes" 2>/dev/null | tr -d '\r'; }

cmd=${1:-}; [ -n "$cmd" ] || usage
shift
case $cmd in
  start)
    extra=""
    while [ $# -gt 0 ]; do
      case $1 in
        --interval|--seconds) case ${2:-} in ''|*[!0-9]*) die "$1 needs a whole number" ;; esac
                              extra="$extra $1 $2"; shift 2 ;;
        *) usage ;;
      esac
    done
    device
    [ "$(running)" = yes ] && die "a soak sampler is already running (stop it first)"
    "$ADB" push "$M/mbmon.sh" "$D/mbmon.sh" >/dev/null || die "push failed"
    "$ADB" shell "rm -f $D/mbmon.stop $SAMPLES $EVENTS; (setsid nohup sh $D/mbmon.sh --soak$extra --out $SAMPLES \
      || nohup sh $D/mbmon.sh --soak$extra --out $SAMPLES) >/dev/null 2>&1 </dev/null &"
    sleep 3
    [ "$(running)" = yes ] || die "sampler did not start"
    echo "tablet-soak: started (samples in $SAMPLES on the tablet)"
    ;;
  status)
    device
    echo "running: $( [ "$(running)" = yes ] && echo yes || echo no )"
    "$ADB" shell "grep -c '^ep=' $SAMPLES 2>/dev/null; tail -n 1 $SAMPLES 2>/dev/null" | tr -d '\r' |
      sed -e '1s/^/samples: /' -e '2s/^/last: /'
    ;;
  stop)
    device
    "$ADB" shell "touch $D/mbmon.stop"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      [ "$(running)" = yes ] || break
      sleep 1
    done
    # The event logcat is the sampler's child; clear a leftover one (sampler killed hard).
    "$ADB" shell "pkill -f '[l]ogcat.*mbsoak_events' 2>/dev/null; rm -f $D/mbmon.stop" >/dev/null 2>&1
    [ "$(running)" = yes ] && die "sampler still running after 15 s"
    echo "tablet-soak: stopped"
    ;;
  pull)
    dir=${1:-}; [ -n "$dir" ] || usage
    shift
    keep=0; [ "${1:-}" = --keep ] && keep=1
    device
    [ "$(running)" = yes ] && die "stop the sampler before pulling"
    mkdir -p "$dir"
    # Samples are numeric key=value lines by construction; event lines keep only their names (no fields).
    "$ADB" exec-out cat "$SAMPLES" | grep -E '^(# mbmon|ep=)' >"$dir/tablet-soak.txt"
    "$ADB" exec-out cat "$EVENTS" 2>/dev/null | python3 "$M/mblog.py" filter --side tablet --events \
      >"$dir/tablet-events.txt"
    echo "tablet-soak: $(grep -c '^ep=' "$dir/tablet-soak.txt") samples, $(wc -l <"$dir/tablet-events.txt" | tr -d ' ') events -> $dir"
    [ $keep -eq 1 ] || "$ADB" shell "rm -f $SAMPLES $EVENTS"
    ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
