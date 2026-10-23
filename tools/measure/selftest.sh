#!/usr/bin/env bash
# Offline self-test of the measurement kit (T-173). Touches no device: adb, top, ioreg, ps, lsof, pgrep and sw_vers
# are replaced by stubs, /proc and /sys by a fake tree, host.log by a temp file. Synthetic inputs: testdata/.
#
# Usage: tools/measure/selftest.sh        # exit 0 = all checks passed; KEEP=1 keeps the temp dir
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TD="$HERE/testdata"
tmp="$(mktemp -d -t mb-selftest)"
trap '[ -n "${KEEP:-}" ] && echo "selftest: kept $tmp" || rm -rf "$tmp"' EXIT
export PYTHONPYCACHEPREFIX="$tmp/pyc"
fail=0
ok() { echo "    ok: $1"; }
bad() { echo "    FAIL: $1"; fail=1; }
# expect <label> <file> <fixed string, spaces squeezed>
expect() {
  if tr -s ' ' <"$2" | grep -q -F -- "$3"; then ok "$1"; else bad "$1 (missing: $3)"; fi
}

echo "==> syntax"
for f in "$ROOT/scripts/device-smoke.sh" "$HERE/macmon.sh" "$HERE/game-ab.sh" "$HERE/selftest.sh" "$ROOT"/tools/soak/*.sh; do
  bash -n "$f" && ok "bash -n ${f#$ROOT/}" || bad "bash -n ${f#$ROOT/}"
done
sh -n "$HERE/mbmon.sh" && ok "sh -n tools/measure/mbmon.sh" || bad "sh -n mbmon.sh"
for f in "$HERE"/*.py "$ROOT"/tools/soak/*.py; do
  python3 -m py_compile "$f" && ok "py_compile ${f#$ROOT/}" || bad "py_compile ${f#$ROOT/}"
done

echo "==> privacy filter"
python3 "$HERE/mblog.py" filter --side tablet --agp <"$TD/tablet_logcat.txt" >"$tmp/t.txt"
python3 "$HERE/mblog.py" filter --side host <"$TD/host_log.txt" >"$tmp/h.txt"
python3 "$HERE/mblog.py" filter --side tablet --events <"$TD/tablet_logcat.txt" >"$tmp/e.txt"
expect "tablet stats kept" "$tmp/t.txt" "render stats fps=119.0"
expect "codec_start kept (no sid/gen)" "$tmp/t.txt" "decoder codec_start name=OMX.hisi.video.decoder.hevc"
expect "AGP fps kept as a number" "$tmp/t.txt" "agp lcd_fps fps=120"
expect "host latency kept" "$tmp/h.txt" "enc_ms_p50_95_99_max=7.0/8.0/9.0/9.5"
expect "events: names only" "$tmp/e.txt" "decoder give_up"

echo "==> mbmon.sh (fake /proc, /sys)"
F="$tmp/fake"
mkdir -p "$F/proc/101/task/1" "$F/proc/101/task/2" "$F/proc/101/task/3" "$F/proc/101/fd" "$F/proc/202" \
  "$F/sys/devices/system/cpu/cpufreq/policy0" "$F/sys/class/thermal/thermal_zone0" "$F/sys/class/thermal/thermal_zone1" \
  "$F/sys/class/devfreq/gpufreq" "$F/sys/class/graphics/fb0" "$F/out"
printf 'cpu  100 0 50 1000 10 0 5 0 0 0\ncpu0 1 0 1 1 0 0 0 0 0 0\ncpu1 1 0 1 1 0 0 0 0 0 0\n' >"$F/proc/stat"
echo '12345.67 99999.00' >"$F/proc/uptime"
echo '101 (atebridge.client) S 1 1 0 0 -1 4194560 100 0 0 0 250 50 0 0 20 0 30 0' >"$F/proc/101/stat"
echo '202 (surface flinger) S 1 1 0 0 -1 4194560 100 0 0 0 40 10 0 0 20 0 30 0' >"$F/proc/202/stat"
echo 'mb-ctl-read-3' >"$F/proc/101/task/1/comm"
echo 'mb-ctl-read-4' >"$F/proc/101/task/2/comm"
echo 'Binder:101_2' >"$F/proc/101/task/3/comm"
touch "$F/proc/101/fd/0" "$F/proc/101/fd/1"
echo 1800000 >"$F/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq"
echo soc_thermal >"$F/sys/class/thermal/thermal_zone0/type"; echo 37500 >"$F/sys/class/thermal/thermal_zone0/temp"
echo modem >"$F/sys/class/thermal/thermal_zone1/type"; echo 30000 >"$F/sys/class/thermal/thermal_zone1/temp"
echo 840000000 >"$F/sys/class/devfreq/gpufreq/cur_freq"
echo 'lcd_fps_scence current_fps:120' >"$F/sys/class/graphics/fb0/lcd_fps_scence"
MBMON_ROOT="$F" MBMON_STOP="$F/out/stop" MBMON_PIDS='P_client=101 P_sf=202' \
  sh "$HERE/mbmon.sh" --seconds 1 --out "$F/out/mbmon.txt"
MBMON_ROOT="$F" MBMON_STOP="$F/out/stop" MBMON_PIDS='P_client=101 P_sf=202' \
  sh "$HERE/mbmon.sh" --soak --interval 1 --seconds 1 --out "$F/out/mbsoak.txt"
expect "perf ticks (comm with a space)" "$F/out/mbmon.txt" "t_client=300 t_sf=50"
expect "perf freq/temp/panel" "$F/out/mbmon.txt" "f_cpu0=1800000 f_gpu=840000000 temp_soc_thermal=37500 panel_hz=120"
expect "soak fds and thread groups" "$F/out/mbsoak.txt" "fds=2 threads=3 thr_Binder=1 thr_mb-ctl-read=2"
expect "perf: missing process group is -, not 0" "$F/out/mbmon.txt" "t_codec=- t_hal=-"
# A client whose fd dir and thread names cannot be read (no run-as here): unavailable, not zero.
mkdir -p "$F/proc/303/task/1" "$F/proc/303/fd"
echo 'mb-video-1' >"$F/proc/303/task/1/comm"
touch "$F/proc/303/fd/0"
chmod 000 "$F/proc/303/fd" "$F/proc/303/task/1/comm"
MBMON_ROOT="$F" MBMON_STOP="$F/out/stop" MBMON_PIDS='P_client=303' \
  sh "$HERE/mbmon.sh" --soak --interval 1 --seconds 1 --out "$F/out/mbsoak_denied.txt"
chmod 755 "$F/proc/303/fd"; chmod 644 "$F/proc/303/task/1/comm"
if [ "$(id -u)" = 0 ]; then
  ok "unreadable fds/threads (skipped: root reads everything)"
else
  expect "unreadable fds/threads are -" "$F/out/mbsoak_denied.txt" "pid=303 pss_kb=- codec_res=- fds=- threads=-"
fi

echo "==> an.py"
python3 "$HERE/an.py" "$TD/mbmon.txt" --log "$TD/tablet_logcat.txt" --window 15 >"$tmp/an.txt"
python3 "$HERE/an.py" "$TD/mbmon.txt" --log "$TD/tablet_logcat.txt" >>"$tmp/an.txt"
expect "cpu shares (pid change skipped)" "$tmp/an.txt" "total 160.0/800 client 60.0 sf 15.0 codec 10.0 hal 9.0 adbd 12.0 logd 2.0"
expect "windows" "$tmp/an.txt" "window 3: t=30..32 s (3 samples)"
expect "panel distribution" "$tmp/an.txt" "panel_hz (node): 120:76% 60:24%"
expect "log join" "$tmp/an.txt" "log: recv_fps 100.0 vsync_ms_p50 8.34 display_hz 120:67% 60:33% agp_lcd_fps 120:1 agp_touch 1"

echo "==> stubs for adb and the macOS tools"
B="$tmp/bin"; mkdir -p "$B" "$tmp/logs"
cat >"$B/top" <<EOF
#!/bin/bash
printf '4001000 I video sid=77 gen=1 ev=latency frames=120 enc_ms_p50_95_99_max=7.0/8.0/9.0/9.5\n4001100 I video sid=77 gen=1 ev=pipeline_retry\n4001200 I input sid=77 gen=1 ev=input_release cause=x events=1\n4001300 I input sid=77 gen=1 ev=input_release cause=x events=1\n' >>"$tmp/logs/host.log"
cat <<'T'
Processes: 500 total
CPU usage: 1.0% user, 1.0% sys, 98.0% idle

PID    %CPU COMMAND
1      0.0  launchd
Processes: 500 total
CPU usage: 10.5% user, 4.5% sys, 85.0% idle

PID    %CPU COMMAND
26019  12.3 MateBridgeApp
100    20.0 WindowServer
0      1.5  kernel_task
555    55.5 Some Game
777    3.0  top
T
EOF
cat >"$B/ioreg" <<'EOF'
#!/bin/bash
echo '  "PerformanceStatistics" = {"Tiler Utilization %"=10,"Renderer Utilization %"=50,"Device Utilization %"=54}'
EOF
cat >"$B/pgrep" <<'EOF'
#!/bin/bash
echo 26019
EOF
cat >"$B/ps" <<'EOF'
#!/bin/bash
case "$*" in
  *rss=*) echo ' 68464' ;;
  *-M*) echo 'USER PID TT %CPU STAT PRI STIME UTIME COMMAND'; for i in 1 2 3 4 5 6 7 8; do echo "u 26019 ?? 0.0 S 31T 0:00.01 0:00.01 x"; done ;;
esac
EOF
cat >"$B/lsof" <<'EOF'
#!/bin/bash
echo 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME'
for i in $(seq 1 40); do echo "MateBridg 26019 u ${i}u REG 1,1 0 1 /x"; done
EOF
cat >"$B/sw_vers" <<'EOF'
#!/bin/bash
case "$1" in -productVersion) echo 27.0.1 ;; -buildVersion) echo 26A434 ;; esac
EOF
cat >"$B/adb" <<EOF
#!/bin/bash
case "\$*" in
  get-state) echo device ;;
  "shell getprop ro.product.brand") echo HUAWEI ;;
  "shell getprop ro.build.display.id") echo 'MRDI-W09 4.3.0.145(C432E2R1P1)' ;;
  "shell dumpsys package dev.matebridge.client") echo '    versionCode=1180 minSdk=29 targetSdk=34' ;;
  "logcat -d -v epoch") cat "$TD/tablet_logcat.txt" ;;
  "logcat -v epoch -T 1") echo '  1791099999.000  1  1 I MB/render: 4999000 I render sid=1 gen=1 ev=stats fps=1.0'
                          cat "$TD/tablet_logcat.txt"; exec sleep 30 ;;
  *) echo "adb stub: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$B"/*
: >"$tmp/logs/host.log"

echo "==> macmon.sh + macan.py (stubs)"
PATH="$B:$PATH" MB_HOST_LOG_DIR="$tmp/logs" bash "$HERE/macmon.sh" --interval 1 --count 2 --soak --proc 'Some Game' --proc Absent \
  --out "$tmp/macmon.txt"
expect "top fields" "$tmp/macmon.txt" "cpu_user=10.5 cpu_sys=4.5 cpu_idle=85.0 cpu_MateBridgeApp=12.3 cpu_WindowServer=20.0 cpu_kernel_task=1.5 cpu_Some_Game=55.5 cpu_Absent=- top_other_cpu=0.0"
expect "gpu fields" "$tmp/macmon.txt" "gpu_dev=54 gpu_ren=50 gpu_til=10"
expect "soak fields" "$tmp/macmon.txt" "pid=26019 instances=1 rss_kb=68464 fds=40 threads=8 ev_pipeline_retry=1 ev_input_release=2"
python3 "$HERE/macan.py" "$tmp/macmon.txt" --host-log "$tmp/logs/host.log" >"$tmp/macan.txt"
expect "macan sampler field" "$tmp/macan.txt" "cpu_MateBridgeApp 12.3 12.3 12.3"
expect "macan host.log slice" "$tmp/macan.txt" "host video latency enc_ms.p50 1 7.00 7.00 7.00"
ino=$(stat -f %i "$tmp/logs/host.log")
printf 'ep=100 dt=5 cpu_user=1.0 hl_off=500 hl_ino=%s\nep=105 dt=5 cpu_user=1.0 hl_off=100 hl_ino=%s\n' "$ino" "$ino" \
  >"$tmp/macmon_rot.txt"
python3 "$HERE/macan.py" "$tmp/macmon_rot.txt" --host-log "$tmp/logs/host.log" >"$tmp/macan_rot.txt"
expect "macan: offsets going backwards" "$tmp/macan_rot.txt" "slice unavailable: hl_off went backwards"
printf 'ep=100 dt=5 cpu_user=1.0 hl_off=0 hl_ino=1\nep=105 dt=5 cpu_user=1.0 hl_off=100 hl_ino=1\n' >"$tmp/macmon_ino.txt"
python3 "$HERE/macan.py" "$tmp/macmon_ino.txt" --host-log "$tmp/logs/host.log" >"$tmp/macan_ino.txt"
expect "macan: another host.log file" "$tmp/macan_ino.txt" "slice unavailable: samples were taken on another host.log file"

echo "==> tablet-soak.sh pull (adb stub)"
grep -E 'ev=(give_up|release_all)' "$TD/tablet_logcat.txt" >"$tmp/ev_raw.txt"
cat >"$B/adb_soak" <<EOF
#!/bin/bash
case "\$*" in
  get-state) echo device ;;
  "shell getprop ro.product.brand") echo HUAWEI ;;
  shell*pgrep*) : ;;
  shell*wc*mbsoak_events.txt*) wc -c <"$tmp/ev_raw.txt" ;;
  shell*wc*mbsoak.txt*) wc -c <"$TD/tablet_soak.txt" ;;
  "exec-out cat /data/local/tmp/mbsoak_events.txt")
    if [ -n "\${TRUNC:-}" ]; then head -c 100 "$tmp/ev_raw.txt"; else cat "$tmp/ev_raw.txt"; fi ;;
  "exec-out cat /data/local/tmp/mbsoak.txt") cat "$TD/tablet_soak.txt" ;;
  shell\ rm*) echo "\$*" >>"$tmp/adb_rm.log" ;;
  *) echo "adb stub: unexpected \$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$B/adb_soak"
if TRUNC=1 ADB="$B/adb_soak" bash "$ROOT/tools/soak/tablet-soak.sh" pull "$tmp/pull" >/dev/null 2>&1; then
  bad "truncated pull must fail"
elif [ -e "$tmp/adb_rm.log" ] || [ -e "$tmp/pull/tablet-soak.txt" ] || [ -n "$(ls -A "$tmp/pull")" ]; then
  bad "truncated pull deleted tablet files or left output"
else
  ok "truncated pull fails, deletes nothing, leaves no partial files"
fi
if ADB="$B/adb_soak" bash "$ROOT/tools/soak/tablet-soak.sh" pull "$tmp/pull" >/dev/null 2>&1 &&
   [ -s "$tmp/adb_rm.log" ]; then
  ok "complete pull deletes the tablet files"
else
  bad "complete pull"
fi
expect "pulled samples" "$tmp/pull/tablet-soak.txt" "thr_mb-ctl-read=2"
expect "pulled events are names only" "$tmp/pull/tablet-events.txt" "decoder give_up"

echo "==> device-smoke.sh (adb stub, temp host.log)"
cp "$TD/host_log.txt" "$tmp/logs/host.log"
( sleep 1.5; cat "$TD/host_log.txt" >>"$tmp/logs/host.log" ) &
PATH="$B:$PATH" ADB="$B/adb" MB_HOST_LOG_DIR="$tmp/logs" \
  bash "$ROOT/scripts/device-smoke.sh" --seconds 4 --content synthetic --run 1 --runs 3 --out "$tmp/smoke" \
  >"$tmp/smoke.txt" 2>"$tmp/smoke.err"
wait
expect "header: builds" "$tmp/smoke.txt" "host_sha: 588332f"
expect "header: apk" "$tmp/smoke.txt" "apk_sha: 588332f (versionCode 1180)"
expect "header: OS" "$tmp/smoke.txt" "harmonyos: MRDI-W09_4.3.0.145(C432E2R1P1)"
expect "header: macOS" "$tmp/smoke.txt" "macos: 27.0.1 (26A434)"
expect "header: codec" "$tmp/smoke.txt" "codec: hevc / OMX.hisi.video.decoder.hevc is_hw=1 lowlat=off oprate=max"
expect "header: transport" "$tmp/smoke.txt" "transport: usb (setting auto)"
expect "header: hz" "$tmp/smoke.txt" "real_hz: 119.9 (vsync p50 8.34 ms; display_hz 120.0)"
expect "header: runs" "$tmp/smoke.txt" "run: 1 of 3"
expect "tablet window (first logcat line skipped)" "$tmp/smoke.txt" "tablet decoder stats recv_fps 3 100.00 118.00 120.00 -"
expect "tablet counters" "$tmp/smoke.txt" "tablet decoder stats drop 3 1.00 1.90 2.00 3"
expect "host window (appended bytes only)" "$tmp/smoke.txt" "host video latency enc_ms.p50 3 7.20 7.38 7.40 -"
expect "host counters" "$tmp/smoke.txt" "host net stats idr 3 0.00 0.90 1.00 1"
[ "$(ls "$tmp/smoke" | wc -l | tr -d ' ')" = 5 ] && ok "--out keeps 5 files" || bad "--out file count"
PATH="$B:$PATH" ADB="$B/adb" MB_HOST_LOG_DIR="$tmp/logs" \
  bash "$ROOT/scripts/device-smoke.sh" --header-only >"$tmp/smoke_h.txt" 2>/dev/null
expect "--header-only" "$tmp/smoke_h.txt" "duration_s: -"

echo "==> soak summarize.py"
python3 "$ROOT/tools/soak/summarize.py" --host "$TD/host_soak.txt" --tablet "$TD/tablet_soak.txt" \
  --events "$TD/tablet_events.txt" --header "$tmp/smoke.txt" >"$tmp/soak.txt"
expect "rss slope" "$tmp/soak.txt" "host rss MB/h 1.000"
expect "pss slope" "$tmp/soak.txt" "tablet pss MB/h 2.000"
expect "thread prefix slope" "$tmp/soak.txt" "tablet thr mb-ctl-read* /h 0.947"
expect "restarts" "$tmp/soak.txt" "host MateBridgeApp pid changes: 1"
expect "events" "$tmp/soak.txt" "tablet release_all: 2"
expect "header carried over" "$tmp/soak.txt" "apk_sha: 588332f (versionCode 1180)"

echo "==> game-ab.sh + game_ab.py (stubs, two arms x two runs)"
AB="$tmp/ab"; BA="$tmp/binab"; GD="$TD/game_ab"; mkdir -p "$BA" "$AB/logs"
cp "$B/ioreg" "$B/pgrep" "$B/ps" "$B/lsof" "$B/sw_vers" "$BA/"
cat >"$BA/top" <<'EOF'
#!/bin/bash
cat <<'T'
Processes: 500 total
CPU usage: 1.0% user, 1.0% sys, 98.0% idle

PID    %CPU COMMAND
Processes: 500 total
CPU usage: 10.5% user, 4.5% sys, 85.0% idle

PID    %CPU COMMAND
26019  12.3 MateBridgeApp
100    20.0 WindowServer
22742  8.0  VTEncoderXPCServ
555    55.5 Some Game
T
EOF
cat >"$BA/adb" <<'EOF'
#!/bin/bash
case "$*" in
  get-state) echo device ;;
  "shell getprop ro.product.brand") echo HUAWEI ;;
  "shell getprop ro.build.display.id") echo 'MRDI-W09 4.3.0.145(C432E2R1P1)' ;;
  "shell dumpsys package dev.matebridge.client") echo '    versionCode=1180 minSdk=29 targetSdk=34' ;;
  "logcat -d -v epoch") cat "$AB_TABLET_IDENT" ;;
  "logcat -v epoch -T 1") cat "$AB_TABLET_WIN"; exec sleep 30 ;;
  *) echo "adb stub: unexpected $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$BA"/*
# ab_run LABEL ARM ID HOSTWIN [more game-ab.sh args]: ID selects host_ident_ID / tablet_ident_ID / tablet_win_ID
ab_run() {
  local label=$1 arm=$2 id=$3 hw=$4; shift 4
  cp "$GD/host_ident_$id.txt" "$AB/logs/host.log"
  ( sleep 1.3; cat "$GD/$hw" >>"$AB/logs/host.log" ) &
  PATH="$BA:$PATH" ADB="$BA/adb" MB_HOST_LOG_DIR="$AB/logs" MB_MAC_INTERVAL=1 \
    AB_TABLET_IDENT="$GD/tablet_ident_$id.txt" AB_TABLET_WIN="$GD/tablet_win_$id.txt" \
    bash "$HERE/game-ab.sh" "$label" --arm "$arm" --seconds 3 --out "$AB/out" --proc "Some Game" --content synthetic \
    "$@" >/dev/null 2>"$AB/run_$label-$arm.err"
  wait
}
E60=(--expect bitrate_kbps=60000 --expect chroma=sharp --expect width=2240)
E30=(--expect bitrate_kbps=30000 --expect chroma=normal --expect width=2240)
ab_run A1 b60 60 host_win_60a.txt --runs 2 "${E60[@]}"
ab_run A1 b30 30 host_win_30.txt --runs 2 "${E30[@]}"
ab_run A1 b60 60 host_win_60b.txt --runs 2 "${E60[@]}"
ab_run A1 b30 30 host_win_30.txt --runs 2 "${E30[@]}"
ab_run X1 wrong 60 host_win_60a.txt --expect bitrate_kbps=20000 --expect chroma=normal
[ -d "$AB/out/A1/b60-1" ] && [ -d "$AB/out/A1/b60-2" ] && [ -d "$AB/out/A1/b30-2" ] && ok "arm repeat numbering" || bad "arm repeat numbering"
S1="$AB/out/A1/b60-1/summary.txt"
expect "arm 1: arm_check ok" "$S1" "arm_check: ok (bitrate_kbps=60000, chroma=sharp, width=2240)"
expect "arm 1: applied values and chroma source" "$S1" "applied: bitrate_kbps=60000 (tablet) / 60000 (host) chroma=sharp_nearest [host video chroma_stats mode (in window)] size=2240x1472 fps=60 transport=wifi"
expect "arm 1: header" "$S1" "apk_sha: 588332f (versionCode 1180)"
expect "arm 1: header run" "$S1" "run: 1 of 2"
expect "arm 1: sent Mbps" "$S1" "host sent_mbps p50 60.0"
expect "arm 1: gpu_ms" "$S1" "host gpu_ms p50 2.00"
expect "arm 1: retx total" "$S1" "video retx_pkts total 8"
expect "arm 1: retx share of seconds" "$S1" "video retx_pct_s 33.3"
expect "arm 1: srtt p50" "$S1" "video srtt_ms p50 10.0"
expect "arm 1: keyframe requests" "$S1" "keyframe_request 1"
expect "arm 1: cap_dec p50 (1 Hz)" "$S1" "cap_dec_ms p50 (1 Hz) 22.5"
expect "arm 1: stalls from 1 Hz samples" "$S1" "stalls >150 ms 1"
expect "arm 1: tablet recv fps" "$S1" "tablet recv_fps 60.0"
expect "arm 1: skip_pct" "$S1" "tablet skip_pct p50 2.0"
expect "arm 1: Mac gpu" "$S1" "mac gpu_dev p50 54"
expect "arm 1: Mac CPU of the game" "$S1" "mac cpu Some_Game p50 55.5"
expect "arm 1: Mac CPU of the encoder service" "$S1" "mac cpu VTEncoder p50 8.0"
python3 "$HERE/game_ab.py" summary "$AB/out/A1" >"$AB/summary_A1.txt"
expect "summary: arms in recording order" "$AB/summary_A1.txt" "arms (recording order): b60-1 b30-1 b60-2 b30-2"
expect "summary: 2 runs is not a claim" "$AB/summary_A1.txt" "claim_ok: no (fewer than 3 runs: do not quote as a result)"
expect "summary: per-run arm_check" "$AB/summary_A1.txt" "b30-2: ok (bitrate_kbps=30000, chroma=normal, width=2240)"
expect "summary: sent Mbps columns" "$AB/summary_A1.txt" "host sent_mbps p50 60.0 (60.0-60.0) 30.0 (30.0-30.0)"
expect "summary: retx total median and spread" "$AB/summary_A1.txt" "video retx_pkts total 13 (8-18) 0 (0-0)"
expect "summary: retx seconds share" "$AB/summary_A1.txt" "video retx_pct_s 41.7 (33.3-50.0) 0.0 (0.0-0.0)"
expect "summary: stalls median of 1 and 2" "$AB/summary_A1.txt" "stalls >150 ms 1.5 (1-2) 0 (0-0)"
expect "summary: gpu_ms columns" "$AB/summary_A1.txt" "host gpu_ms p50 2.00 (2.00-2.00) 1.00 (1.00-1.00)"
expect "summary: stall source" "$AB/summary_A1.txt" "stalls source: host 1 Hz seconds with cap_dec_ms > 150"
python3 "$HERE/game_ab.py" summary "$AB/out/X1" >"$AB/summary_X1.txt"
expect "mismatch is flagged, the run is kept" "$AB/summary_X1.txt" "wrong-1: MISMATCH (bitrate_kbps expected 20000, applied 60000/60000; chroma expected 420, applied sharp_nearest)"
# no 1 Hz cap_dec samples: stalls fall back to the tablet's 10 s windows and say so
mkdir -p "$AB/fb" && cp -R "$AB/out/A1/b60-1" "$AB/fb/b60-1"
sed -i '' -E 's/ cap_dec_ms=[0-9.]+//' "$AB/fb/b60-1/host.txt"
python3 "$HERE/game_ab.py" arm "$AB/fb/b60-1" >"$AB/fb.txt"
expect "stall fallback to tablet windows" "$AB/fb.txt" "stalls >150 ms 1"
expect "stall fallback is named" "$AB/fb.txt" "tablet 10 s windows with cap_dec_max_us > 150000"
# a profile line inside the window (setting changed mid-run) warns
cp -R "$AB/out/A1/b60-1" "$AB/fb/b60-chg"
echo 'H 1791200005.000 7100500 encoder profile fps=60 bitrate_kbps=30000' >>"$AB/fb/b60-chg/host.txt"
python3 "$HERE/game_ab.py" arm "$AB/fb/b60-chg" >"$AB/chg.txt"
expect "profile line in the window warns" "$AB/chg.txt" "warn: a profile line was logged inside the window"
ls "$AB/out/A1/b60-1" | tr '\n' ' ' >"$AB/files.txt"
expect "only filtered files are kept" "$AB/files.txt" "host_ident.txt host.txt mac.txt meta.txt summary.txt tablet_ident.txt tablet.txt"
# a missing tablet: that part is skipped with a message, the rest is still recorded
cp "$GD/host_ident_60.txt" "$AB/logs/host.log"
PATH="$BA:$PATH" ADB="$AB/no-such-adb" MB_HOST_LOG_DIR="$AB/logs" MB_MAC_INTERVAL=1 \
  bash "$HERE/game-ab.sh" N1 --arm solo --seconds 1 --out "$AB/out" >"$AB/n1.txt" 2>"$AB/n1.err"
expect "no tablet: skipped, said so" "$AB/n1.err" "tablet part skipped"
expect "no tablet: no-window note" "$AB/n1.txt" "note: no tablet window"

echo "==> no clipboard, key, text, path, address or serial content in any output"
# The README documents the same grep for real runs.
if cat "$tmp"/*.txt "$tmp"/smoke/* "$F"/out/*.txt "$AB"/*.txt "$AB"/out/*/*/*.txt "$AB"/fb/*/*.txt |
   grep -n -i -E 'clipboard|clip_|keycode|char=|text=|hello|password|secret|serial|ABC123XYZ|/Users/|(^|[ =:/])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)|com\.example'; then
  bad "forbidden content above"
else
  ok "privacy grep clean"
fi

if [ $fail -eq 0 ]; then echo "selftest: ALL OK"; else echo "selftest: FAILURES"; fi
exit $fail
