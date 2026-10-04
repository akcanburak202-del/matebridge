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
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
      [ "$(running)" = yes ] || break
      sleep 1
    done
    # The stop file stays until the sampler is gone (it removes the file itself on exit); deleting it early would
    # let a sampler that is slow to see it run on forever.
    [ "$(running)" = yes ] && die "sampler still running after 30 s; the stop file stays in place, run stop again"
    # The event logcat is the sampler's child; clear a leftover one (sampler killed hard).
    "$ADB" shell "pkill -f '[l]ogcat.*mbsoak_events' 2>/dev/null; rm -f $D/mbmon.stop" >/dev/null 2>&1
    echo "tablet-soak: stopped"
    ;;
  pull)
    dir=${1:-}; [ -n "$dir" ] || usage
    shift
    keep=0; [ "${1:-}" = --keep ] && keep=1
    device
    [ "$(running)" = yes ] && die "stop the sampler before pulling"
    mkdir -p "$dir" || die "cannot create $dir"
    s_part="$dir/.tablet-soak.txt.part" e_part="$dir/.tablet-events.txt.part" n_part="$dir/.tablet-events.bytes.part"
    trap 'rm -f "$s_part" "$s_part.raw" "$e_part" "$n_part"' EXIT
    remote_size() { "$ADB" shell "[ -f $1 ] && wc -c < $1" 2>/dev/null | tr -d '\r '; }
    s_size=$(remote_size "$SAMPLES")
    e_size=$(remote_size "$EVENTS")
    case $s_size in ''|*[!0-9]*) die "no sample file on the tablet (nothing deleted)" ;; esac
    case $e_size in ''|*[!0-9]*) die "no event file on the tablet (nothing deleted)" ;; esac
    # Samples are numeric key=value lines by construction; event lines keep only their names (no fields). Each
    # transfer is checked against the tablet's byte count, results land via .part + mv, and the tablet files are
    # deleted only after both succeeded.
    "$ADB" exec-out cat "$SAMPLES" >"$s_part.raw" || die "sample transfer failed (nothing deleted)"
    [ "$(wc -c <"$s_part.raw" | tr -d ' ')" = "$s_size" ] || die "sample transfer incomplete (nothing deleted)"
    grep -E '^(# mbmon|ep=)' "$s_part.raw" >"$s_part" || die "no samples in the sample file (nothing deleted)"
    rm -f "$s_part.raw"
    "$ADB" exec-out cat "$EVENTS" | python3 "$M/mblog.py" filter --side tablet --events --bytes-to "$n_part" \
      >"$e_part" || die "event transfer failed (nothing deleted)"
    [ "$(tr -d ' \n' <"$n_part" 2>/dev/null)" = "$e_size" ] || die "event transfer incomplete (nothing deleted)"
    { mv "$s_part" "$dir/tablet-soak.txt" && mv "$e_part" "$dir/tablet-events.txt"; } || die "cannot write $dir"
    echo "tablet-soak: $(grep -c '^ep=' "$dir/tablet-soak.txt") samples, $(wc -l <"$dir/tablet-events.txt" | tr -d ' ') events -> $dir"
    [ $keep -eq 1 ] || "$ADB" shell "rm -f $SAMPLES $EVENTS"
    ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
