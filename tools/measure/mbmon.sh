#!/system/bin/sh
# Tablet sampler (T-173). Runs ON the tablet (toybox sh), started over adb; writes numeric key=value lines only.
#
#   perf (default, 1 Hz): panel rate, temperatures, CPU/GPU frequency and raw CPU ticks (system total and per process
#                         group: client, surfaceflinger, codec services, graphics HAL, adbd, logd). an.py turns the
#                         ticks into CPU shares (% of one core; the system total is out of ncpu x 100, e.g. /800).
#   --soak (60 s):        client PSS, open fds (run-as), threads by name prefix, codec resource lines, and in the
#                         background a logcat that keeps only stability events (counted by tools/soak/summarize.py).
#
# Usage (on the tablet): sh /data/local/tmp/mbmon.sh [--soak] [--seconds N] [--interval S] [--out FILE]
#                                                    [--panel auto|node|sf|none]
#   Stops after --seconds (0 = until stopped) or when /data/local/tmp/mbmon.stop exists.
#   Recipes: tools/measure/README.md. Test hooks: MBMON_ROOT (prefix for /proc and /sys), MBMON_PIDS.

PKG=dev.matebridge.client
R="${MBMON_ROOT:-}"
DIR=/data/local/tmp
mode=perf seconds=0 interval="" out="" panel=auto
while [ $# -gt 0 ]; do
  case $1 in
    --soak) mode=soak; shift ;;
    --seconds) seconds=$2; shift 2 ;;
    --interval) interval=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --panel) panel=$2; shift 2 ;;
    *) echo "mbmon: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ "$mode" = soak ]; then
  : "${interval:=60}"; : "${out:=$DIR/mbsoak.txt}"
else
  : "${interval:=1}"; : "${out:=$DIR/mbmon.txt}"
fi
STOP="${MBMON_STOP:-$DIR/mbmon.stop}"
EVFILE="${out%.txt}_events.txt"
rm -f "$STOP"

ev_pid=""
cleanup() {
  [ -n "$ev_pid" ] && kill "$ev_pid" 2>/dev/null
  rm -f "$STOP"
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

has() { command -v "$1" >/dev/null 2>&1; }

# --- process groups (pids re-resolved every 10 samples; gen= changes when any group changed, so an.py does not
#     take a tick delta across a restart)
P_client="" P_sf="" P_codec="" P_hal="" P_adbd="" P_logd="" gen=0 pidsig=""
find_pids() {
  if [ -n "${MBMON_PIDS:-}" ]; then
    eval "$MBMON_PIDS"
  else
    P_client=$(pidof "$PKG" 2>/dev/null)
    P_sf=$(pidof surfaceflinger 2>/dev/null)
    P_adbd=$(pidof adbd 2>/dev/null)
    P_logd=$(pidof logd 2>/dev/null)
    P_codec=$(ps -A -o PID,NAME 2>/dev/null | grep -i -E 'codec|omx' | while read -r p _; do printf '%s ' "$p"; done)
    P_hal=$(ps -A -o PID,NAME 2>/dev/null | grep -i -E 'composer|allocator' | while read -r p _; do printf '%s ' "$p"; done)
  fi
  sig="$P_client|$P_sf|$P_codec|$P_hal|$P_adbd|$P_logd"
  [ "$sig" != "$pidsig" ] && gen=$((gen + 1))
  pidsig=$sig
}

# utime + stime of the given pids (fields 14, 15 of /proc/<pid>/stat, counted after the ") " that ends comm)
ticks() {
  t=0
  for p in $*; do
    [ -r "$R/proc/$p/stat" ] || continue
    read -r line <"$R/proc/$p/stat"
    rest=${line##*") "}
    set -- $rest
    [ $# -ge 13 ] && t=$((t + ${12} + ${13}))
  done
  echo $t
}

# --- static choices made once
ncpu=$(grep -c '^cpu[0-9]' "$R/proc/stat" 2>/dev/null)
clk=$(getconf CLK_TCK 2>/dev/null); [ -n "$clk" ] || clk=100
zones=""
for z in "$R"/sys/class/thermal/thermal_zone*; do
  [ -r "$z/type" ] && [ -r "$z/temp" ] || continue
  read -r ty <"$z/type"
  case $ty in
    *soc*|*SOC*|*cpu*|*CPU*|*gpu*|*GPU*|*shell*|*SHELL*|*board*|*BOARD*|*battery*|*Battery*)
      name=$(echo "$ty" | tr -c 'A-Za-z0-9_\n' '_')
      zones="$zones $name:$z" ;;
  esac
done
gpu_node=""
for d in "$R"/sys/class/devfreq/*; do
  case ${d##*/} in *gpu*|*GPU*|*mali*|*Mali*) [ -r "$d/cur_freq" ] && { gpu_node="$d/cur_freq"; break; } ;; esac
done
panel_node="${MBMON_PANEL_NODE:-$R/sys/class/graphics/fb0/lcd_fps_scence}"
psrc=none
case $panel in
  auto) if [ -r "$panel_node" ]; then psrc=node; elif has dumpsys; then psrc=sf; fi ;;
  node) [ -r "$panel_node" ] && psrc=node ;;
  sf) has dumpsys && psrc=sf ;;
esac

panel_hz() {
  case $psrc in
    node) read -r v <"$panel_node" 2>/dev/null; v=${v##*current_fps:}; v=${v#"${v%%[0-9]*}"}; echo "${v%%[!0-9]*}" ;;
    sf) dumpsys SurfaceFlinger 2>/dev/null | grep -m1 -E 'refresh-rate *:' | sed -E 's/.*: *([0-9]+).*/\1/' ;;
    *) echo "" ;;
  esac
}

perf_sample() {
  read -r up _ <"$R/proc/uptime"
  read -r _ u n s i w q sq st _ <"$R/proc/stat"
  tot=$((u + n + s + i + w + q + sq + ${st:-0}))
  idle=$((i + w))
  line="ep=$(date +%s) up=$up gen=$gen cpu_total=$tot cpu_idle=$idle"
  line="$line t_client=$(ticks $P_client) t_sf=$(ticks $P_sf) t_codec=$(ticks $P_codec) t_hal=$(ticks $P_hal)"
  line="$line t_adbd=$(ticks $P_adbd) t_logd=$(ticks $P_logd)"
  for f in "$R"/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq; do
    [ -r "$f" ] || continue
    d=${f%/scaling_cur_freq}
    read -r v <"$f"
    line="$line f_cpu${d##*/policy}=$v"
  done
  [ -n "$gpu_node" ] && { read -r v <"$gpu_node"; line="$line f_gpu=$v"; }
  for zp in $zones; do
    read -r v <"${zp#*:}/temp" 2>/dev/null && line="$line temp_${zp%%:*}=$v"
  done
  hz=$(panel_hz)
  line="$line panel_hz=${hz:--}"
  echo "$line"
}

soak_sample() {
  pid=$(echo $P_client | cut -d' ' -f1)
  pss=- fds=- threads=- codec=-
  if has dumpsys; then
    pss=$(dumpsys meminfo "$PKG" 2>/dev/null | grep -m1 -E 'TOTAL PSS:|^ *TOTAL +[0-9]' |
      sed -E 's/^ *TOTAL( PSS:)? +([0-9]+).*/\2/')
    codec=$(dumpsys media.resource_manager 2>/dev/null | grep -c -i 'codec')
  fi
  line="ep=$(date +%s) up=$(cut -d' ' -f1 "$R/proc/uptime") pid=${pid:--} pss_kb=${pss:--} codec_res=${codec:--}"
  if [ -n "$pid" ] && [ -d "$R/proc/$pid/task" ]; then
    if has run-as; then
      fds=$(run-as "$PKG" ls "/proc/$pid/fd" 2>/dev/null | wc -l | tr -d ' ')
    elif [ -r "$R/proc/$pid/fd" ]; then
      fds=$(ls "$R/proc/$pid/fd" | wc -l | tr -d ' ')
    fi
    groups=$(cat "$R"/proc/$pid/task/*/comm 2>/dev/null | sed -E 's/([:_-]?[0-9]+)+$//' |
      tr -c 'A-Za-z0-9._\n-' '_' | sort | uniq -c)
    threads=0
    tl=""
    while read -r c nm; do
      [ -n "$c" ] || continue
      threads=$((threads + c))
      tl="$tl thr_${nm:-unnamed}=$c"
    done <<EOF
$groups
EOF
    line="$line fds=${fds:--} threads=$threads$tl"
  else
    line="$line fds=- threads=-"
  fi
  echo "$line"
}

start_events() {
  has logcat || return
  # Only stability events of the MateBridge format; tools/soak/tablet-soak.sh pull keeps just their names.
  logcat -v epoch -T 1 -e '[0-9] [EWID] [a-z_]+ (sid=[0-9]+ gen=[0-9]+ )?ev=(give_up|decoder_previous_stuck|detach_slow|retire_lock_slow|audio_previous_slow|release_all|reconnect|connect_ok|connect_fail|video_lost|transport_migrate|session_failed|app_start|codec_start)( |$)' \
    -f "$EVFILE" >/dev/null 2>&1 &
  ev_pid=$!
}

find_pids
{
  echo "# mbmon v1 mode=$mode interval=$interval clk_tck=$clk ncpu=$ncpu panel_src=$psrc start_ep=$(date +%s)"
} >"$out"
[ "$mode" = soak ] && start_events

k=0 elapsed=0
while :; do
  [ -e "$STOP" ] && break
  # soak: every sample (a client restart must show at once); perf: every 10 s (ps costs CPU)
  if [ $k -gt 0 ] && { [ "$mode" = soak ] || [ $((k % 10)) -eq 0 ]; }; then find_pids; fi
  if [ "$mode" = soak ]; then soak_sample >>"$out"; else perf_sample >>"$out"; fi
  k=$((k + 1))
  j=0
  while [ $j -lt "$interval" ]; do
    [ -e "$STOP" ] && break
    sleep 1
    j=$((j + 1))
  done
  elapsed=$((elapsed + interval))
  [ "$seconds" -gt 0 ] && [ $elapsed -ge "$seconds" ] && break
done
