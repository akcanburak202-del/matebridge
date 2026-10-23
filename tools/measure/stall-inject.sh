#!/usr/bin/env bash
# Video stall injector (T-366): repeatable, short stalls on the Mac -> tablet video TCP stream, using macOS
# dummynet (dnctl) + pf. Only packets whose TCP SOURCE port is the host's video port, going out, are shaped; the
# control port (47001), audio and everything else are untouched. NEEDS sudo (not for --dry-run).
#
# Usage: sudo tools/measure/stall-inject.sh --stall-ms N --every-s S --count K [--port P] [--dir DIR]
#        tools/measure/stall-inject.sh --dry-run --stall-ms N --every-s S --count K [--port P]
#        sudo tools/measure/stall-inject.sh --cleanup      remove leftovers (anchor, pipe, pf reference)
#        sudo tools/measure/stall-inject.sh --status       show what is installed (must be empty after a session)
#   --stall-ms N   length of each stall (bandwidth ~0: 8 Kbit/s) in milliseconds
#   --every-s S    seconds between stall starts (the first stall comes S seconds after the start)
#   --count K      number of stalls
#   --port P       video TCP port; default: the last `session_started video_port=` in host.log, else 47002.
#                  The port used is printed; a --port that differs from host.log is warned about.
#   --dir DIR      stall times are written to DIR/stalls.txt (use the arm folder game-ab.sh is filling)
#   --dry-run      print the commands that would run; needs no root, loads nothing, writes nothing
# stalls.txt, one line per stall:  stall n=1 epoch_ms=<wall clock> mono_ms=<host log clock> end_mono_ms=<..> ms=<N> port=<P>
#   mono_ms is the same clock as the first column of host.log (DispatchTime uptime, ns/1e6), so game_ab.py can
#   place each stall on the host's per-second samples.
# Cleanup: on exit, Ctrl+C, TERM, HUP and on errors the pf anchor, the dummynet pipe and the pf reference taken
# here are removed; pf goes back to its previous enabled/disabled state (reference-counted `pfctl -E` / `-X`).
# Existing pf rules are never edited: the rule lives in its own anchor under com.apple/, which the stock macOS
# pf.conf already evaluates (dummynet-anchor "com.apple/*").
# Env: MB_HOST_LOG_DIR (default ~/Library/Logs/MateBridge), MB_STALL_STATE (state file, default
#      /var/tmp/matebridge-stall.state)
set -uo pipefail

ANCHOR="com.apple/matebridge-stall"
PIPE=4700
BW_STALL="8Kbit/s"
STATE="${MB_STALL_STATE:-/var/tmp/matebridge-stall.state}"
LOGDIR="${MB_HOST_LOG_DIR:-$HOME/Library/Logs/MateBridge}"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit "${1:-2}"; }
die() { echo "stall-inject: $*" >&2; exit 2; }

stall_ms="" every_s="" count="" port="" dir="" dry=0 mode=run
while [ $# -gt 0 ]; do
  case $1 in
    --stall-ms) stall_ms=${2:?}; shift 2 ;;
    --every-s) every_s=${2:?}; shift 2 ;;
    --count) count=${2:?}; shift 2 ;;
    --port) port=${2:?}; shift 2 ;;
    --dir) dir=${2:?}; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --cleanup) mode=cleanup; shift ;;
    --status) mode=status; shift ;;
    -h|--help) usage 0 ;;
    *) echo "stall-inject: unknown argument '$1'" >&2; usage ;;
  esac
done
isnum() { case $1 in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# run CMD...: print it; execute unless --dry-run
run() {
  echo "+ $*"
  [ $dry -eq 1 ] && return 0
  "$@"
}
# run_in TEXT CMD...: same, with TEXT on stdin
run_in() {
  local text=$1; shift
  echo "+ echo '$text' | $*"
  [ $dry -eq 1 ] && return 0
  printf '%s\n' "$text" | "$@"
}
need_root() {
  if [ "$dry" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    echo "stall-inject: this changes the packet filter and needs root. Nothing was changed." >&2
    echo "stall-inject: run it with sudo, or add --dry-run to only print the commands." >&2
    exit 2
  fi
}

pipe_present() { dnctl list 2>/dev/null | grep -q "^0*$PIPE:"; }

do_status() {
  need_root
  if [ $dry -eq 1 ]; then
    run pfctl -s info; run pfctl -a "$ANCHOR" -s rules; run dnctl list; return 0
  fi
  echo "pf: $(pfctl -s info 2>/dev/null | head -n 1)"
  echo "anchor $ANCHOR rules:"; pfctl -a "$ANCHOR" -s rules 2>&1 | sed 's/^/  /'
  echo "dummynet pipes:"; dnctl list 2>&1 | sed 's/^/  /'
  if [ -f "$STATE" ]; then echo "state file $STATE: present"; else echo "state file: none"; fi
  local rules; rules="$(pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -c .)"
  if [ "$rules" = 0 ] && ! pipe_present && [ ! -f "$STATE" ]; then
    echo "status: clean"
  else
    echo "status: LEFTOVERS (run --cleanup)"; return 1
  fi
}

cleanup_done=0
do_cleanup() {
  [ $cleanup_done -eq 1 ] && return 0
  cleanup_done=1
  [ $dry -eq 1 ] && return 0
  local token=""
  [ -f "$STATE" ] && token="$(sed -n 's/^token=//p' "$STATE")"
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
  dnctl pipe delete "$PIPE" >/dev/null 2>&1
  [ -n "$token" ] && pfctl -X "$token" >/dev/null 2>&1
  rm -f "$STATE"
  echo "stall-inject: cleaned up (anchor, pipe $PIPE, pf reference)" >&2
}

if [ "$mode" = status ]; then do_status; exit $?; fi
if [ "$mode" = cleanup ]; then
  need_root
  if [ $dry -eq 1 ]; then
    run pfctl -a "$ANCHOR" -F all; run dnctl pipe delete "$PIPE"; echo "+ pfctl -X <token from $STATE>"; exit 0
  fi
  do_cleanup; do_status; exit $?
fi

# --- run mode
isnum "$stall_ms" && [ "$stall_ms" -gt 0 ] || die "--stall-ms needs a positive whole number"
isnum "$every_s" && [ "$every_s" -gt 0 ] || die "--every-s needs a positive whole number"
isnum "$count" && [ "$count" -gt 0 ] || die "--count needs a positive whole number"
[ "$stall_ms" -lt $((every_s * 1000)) ] || die "--stall-ms must be shorter than --every-s"
if [ -n "$port" ]; then
  isnum "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "--port needs 1-65535"
fi
need_root

# the video port from host.log (read-only); a user-given --port wins but a mismatch is said out loud
logged=""
for f in "$LOGDIR/host.log" "$LOGDIR/host.1.log"; do
  [ -f "$f" ] || continue
  logged="$(grep -a 'ev=session_started' "$f" | tail -n 1 | grep -o 'video_port=[0-9]*' | cut -d= -f2)"
  [ -n "$logged" ] && break
done
if [ -z "$port" ]; then
  if [ -n "$logged" ]; then port=$logged; echo "stall-inject: video port $port (from host.log)"
  else port=47002; echo "stall-inject: video port $port (default; no session_started line in host.log)"; fi
else
  echo "stall-inject: video port $port (from --port)"
  if [ -n "$logged" ] && [ "$logged" != "$port" ]; then
    echo "stall-inject: WARNING host.log says the video port is $logged" >&2
  fi
fi
out=""
if [ -n "$dir" ]; then
  [ $dry -eq 1 ] || [ -d "$dir" ] || die "--dir $dir does not exist"
  out="$dir/stalls.txt"
fi

# same clock as host.log's first column: DispatchTime uptime (mach_absolute_time, no sleep time)
stamp() { python3 -I -c 'import time; print(time.time_ns() // 1000000, time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) // 1000000)'; }

trap do_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

echo "stall-inject: $count stalls of ${stall_ms} ms every ${every_s} s, tcp source port $port, outgoing only"
[ $dry -eq 1 ] && echo "stall-inject: DRY RUN, nothing is executed"
if [ $dry -eq 0 ] && { [ -f "$STATE" ] || pipe_present; }; then
  cleanup_done=1   # not ours: the trap must not remove it
  die "leftovers of an earlier run found: run  sudo $0 --cleanup  first"
fi

run dnctl pipe "$PIPE" config bw 0 queue 100
run_in "dummynet out proto tcp from any port $port to any pipe $PIPE" pfctl -a "$ANCHOR" -f -
if [ $dry -eq 1 ]; then
  echo "+ pfctl -E    (reference-counted; prints a token that is kept in $STATE)"
else
  token="$(pfctl -E 2>&1 | sed -n 's/^Token *: *//p' | head -n 1)"
  [ -n "$token" ] || { echo "stall-inject: could not take the pf reference (pfctl -E gave no token)" >&2; exit 1; }
  printf 'token=%s\npipe=%s\nanchor=%s\n' "$token" "$PIPE" "$ANCHOR" >"$STATE"
  echo "stall-inject: shaping armed (pf token kept in $STATE)"
fi
if [ -n "$out" ]; then
  if [ $dry -eq 1 ]; then echo "+ (stall times are written to $out)"; else : >"$out" || exit 1; fi
fi

secs="$(LC_ALL=C awk -v ms="$stall_ms" 'BEGIN { printf "%.3f", ms / 1000 }')"
n=1
while [ "$n" -le "$count" ]; do
  if [ $dry -eq 1 ]; then
    if [ "$n" -le 2 ]; then
      echo "+ sleep $every_s"
      run dnctl pipe "$PIPE" config bw "$BW_STALL"
      echo "+ sleep $secs"
      run dnctl pipe "$PIPE" config bw 0
    elif [ "$n" -eq 3 ]; then
      echo "+ ... the same steps, up to stall $count"
    fi
    n=$((n + 1)); continue
  fi
  sleep "$every_s"
  read -r ep mono < <(stamp)
  dnctl pipe "$PIPE" config bw "$BW_STALL" >/dev/null 2>&1 || { echo "stall-inject: dnctl failed" >&2; exit 1; }
  sleep "$secs"
  dnctl pipe "$PIPE" config bw 0 >/dev/null 2>&1 || { echo "stall-inject: dnctl release failed" >&2; exit 1; }
  read -r _ end_mono < <(stamp)
  line="stall n=$n epoch_ms=$ep mono_ms=$mono end_mono_ms=$end_mono ms=$stall_ms port=$port"
  echo "$line"
  [ -n "$out" ] && echo "$line" >>"$out"
  n=$((n + 1))
done
echo "stall-inject: done"
exit 0
