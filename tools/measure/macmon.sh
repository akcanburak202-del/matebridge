#!/usr/bin/env bash
# Host sampler (T-173): one numeric key=value line per interval. Read-only; opens no window.
#
#   default (5 s): system CPU (user/sys/idle %), GPU utilisation (ioreg IOAccelerator: device/renderer/tiler %),
#                  %CPU of MateBridgeApp, WindowServer, kernel_task and every --proc name, and the busiest other
#                  process's %CPU without its name (top_other_cpu). hl_off= is the host.log size, so macan.py can
#                  cut the matching host.log slice.
#   --soak:        adds MateBridgeApp pid, instance count, RSS (KB), open files (lsof) and threads (ps -M), and how
#                  many of these host.log events appeared since the previous sample: pipeline_retry, input_release,
#                  session_started, display_recreate, app_start, keyframe_request.
#
# Usage: tools/measure/macmon.sh [--interval S] [--seconds N] [--count N] [--soak] [--proc NAME]... [--out FILE]
#   --seconds 0 and --count 0 (defaults) run until Ctrl-C. Lines go to stdout, or are appended to --out.
#   The %CPU values come from `top -l 2` (its second sample is the real average over the interval).
set -uo pipefail
export LC_ALL=C   # decimal point, not the Turkish comma (NOTES 2026-09-30)

interval=5 seconds=0 count=0 soak=0 out="" procs="MateBridgeApp|WindowServer|kernel_task"  # "|": names may hold spaces
while [ $# -gt 0 ]; do
  case $1 in
    --interval) interval=${2:?}; shift 2 ;;
    --seconds) seconds=${2:?}; shift 2 ;;
    --count) count=${2:?}; shift 2 ;;
    --soak) soak=1; shift ;;
    --proc) procs="$procs|${2:?}"; shift 2 ;;
    --out) out=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "macmon: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
LOGDIR="${MB_HOST_LOG_DIR:-$HOME/Library/Logs/MateBridge}"
HOSTLOG="$LOGDIR/host.log"
EVENTS="pipeline_retry input_release session_started display_recreate app_start keyframe_request"

emit() { if [ -n "$out" ]; then echo "$1" >>"$out"; else echo "$1"; fi; }
size_of() { stat -f %z "$1" 2>/dev/null || echo 0; }

# One sample of top: blocks for $interval seconds and prints "cpu_user=.. cpu_sys=.. cpu_idle=.. cpu_<proc>=.. top_other_cpu=.."
top_fields() {
  top -l 2 -s "$interval" -n 15 -o cpu -stats pid,cpu,command 2>/dev/null | awk -v procs="$procs" '
    BEGIN { n = split(procs, p, "|"); for (i = 1; i <= n; i++) { want[p[i]] = 1; cpu[p[i]] = 0 } }
    /^Processes:/ { snap++; hdr = 0; next }
    snap == 2 && /^CPU usage:/ { gsub("%", ""); u = $3; s = $5; idl = $7; next }
    snap == 2 && /^ *PID/ { hdr = 1; next }
    snap == 2 && hdr && NF >= 3 {
      cmd = $3; for (i = 4; i <= NF; i++) cmd = cmd " " $i
      if (cmd in want) cpu[cmd] += $2
      else if (cmd != "top" && $2 + 0 > other) other = $2 + 0
    }
    END {
      printf "cpu_user=%s cpu_sys=%s cpu_idle=%s", (u == "" ? "-" : u), (s == "" ? "-" : s), (idl == "" ? "-" : idl)
      for (i = 1; i <= n; i++) { k = p[i]; gsub(/[^A-Za-z0-9_]/, "_", k); printf " cpu_%s=%.1f", k, cpu[p[i]] }
      printf " top_other_cpu=%.1f", other
    }'
}

gpu_fields() {
  # All three keys sit in one PerformanceStatistics line; the first accelerator that has them wins.
  ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | awk '
    function val(line, key,   s) {
      if (!match(line, "\"" key " Utilization %\"=[0-9]+")) return ""
      s = substr(line, RSTART, RLENGTH); sub(/.*=/, "", s); return s
    }
    d == "" { d = val($0, "Device") }
    r == "" { r = val($0, "Renderer") }
    t == "" { t = val($0, "Tiler") }
    END { printf "gpu_dev=%s gpu_ren=%s gpu_til=%s", (d == "" ? "-" : d), (r == "" ? "-" : r), (t == "" ? "-" : t) }'
}

ev_off=$(size_of "$HOSTLOG")
# Sets soak_line (not printed: it must run in this shell so ev_off carries over to the next sample).
soak_line=""
soak_fields() {
  local pid n rss fds thr now chunk_counts name c
  pid=$(pgrep -x MateBridgeApp 2>/dev/null | head -1)
  n=$(pgrep -x MateBridgeApp 2>/dev/null | wc -l | tr -d ' ')
  rss=- fds=- thr=-
  if [ -n "$pid" ]; then
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    fds=$(lsof -n -P -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    thr=$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  fi
  soak_line="pid=${pid:--} instances=$n rss_kb=${rss:--} fds=${fds:--} threads=${thr:--}"
  now=$(size_of "$HOSTLOG")
  chunk_counts=$(
    if [ "$now" -ge "$ev_off" ]; then
      tail -c +$((ev_off + 1)) "$HOSTLOG" 2>/dev/null
    else # rotated since the last sample: rest of the old file, then the new one
      tail -c +$((ev_off + 1)) "$LOGDIR/host.1.log" 2>/dev/null
      cat "$HOSTLOG" 2>/dev/null
    fi | grep -o -E ' ev=[a-z_]+( |$)' | tr -d ' ' | sort | uniq -c)
  for name in $EVENTS; do
    c=$(echo "$chunk_counts" | awk -v e="ev=$name" '$2 == e { print $1 }')
    soak_line="$soak_line ev_$name=${c:-0}"
  done
  ev_off=$now
}

[ -n "$out" ] && : >>"$out"
emit "# macmon v1 interval=$interval soak=$soak procs=$(echo "$procs" | tr '| ' ',_') start_ep=$(date +%s)"
start=$(date +%s) samples=0
trap 'exit 0' INT TERM
while :; do
  hl=$(size_of "$HOSTLOG")
  t=$(top_fields)          # takes $interval seconds
  line="ep=$(date +%s) dt=$interval $t $(gpu_fields) hl_off=$hl"
  if [ $soak -eq 1 ]; then soak_fields; line="$line $soak_line"; fi
  emit "$line"
  samples=$((samples + 1))
  if [ "$count" -gt 0 ] && [ $samples -ge "$count" ]; then break; fi
  if [ "$seconds" -gt 0 ] && [ $(($(date +%s) - start)) -ge "$seconds" ]; then break; fi
done
