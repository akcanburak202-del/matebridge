# Measurement kit (T-173)

Versioned replacements for the scratch tools of October 2026 (`mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`, NOTES
2026-10-02 ~21:30 and 2026-10-03 ~00:55), rewritten from the NOTES recipes, plus the one-command smoke
`scripts/device-smoke.sh`. bash, POSIX sh (on the tablet) and python3 stdlib only. Soak tools: `tools/soak/`.

| File | Runs on | What it does |
|---|---|---|
| `scripts/device-smoke.sh` | Mac | Build identity + 60 s numeric stats window, p50/p95 to stdout. Read-only on both devices. |
| `mbmon.sh` | tablet (`adb shell sh`) | 1 Hz panel rate, temperatures, CPU/GPU frequency, CPU ticks per process group. `--soak`: 60 s PSS, fds, threads, codec lines, event logcat. |
| `an.py` | Mac | Tablet window summary of `mbmon.txt`, optionally joined with a filtered logcat capture. |
| `macmon.sh` | Mac | 5 s system/per-process CPU, GPU utilisation. `--soak`: RSS, fds, threads, host.log event counts. |
| `macan.py` | Mac | Host window summary of `macmon.sh` output, optionally with the matching `host.log` slice. |
| `mblog.py` | Mac | Shared parser, the privacy filter (`mblog.py filter`), percentiles, the result header. |
| `smoke.py` | Mac | The report behind `device-smoke.sh`. |
| `selftest.sh` | Mac | Offline test with stubs and `testdata/` (synthetic, numbers only). Touches no device. |

## Result header (rule)

Every tool prints this block first. A number goes into NOTES only together with its header.

```text
== result header (T-173) ==
date_utc: 2026-10-05T09:12Z
host_sha: 588332f
apk_sha: 588332f (versionCode 1180)
macos: 27.0.1 (26A434)
harmonyos: MRDI-W09_4.3.0.145(...)
codec: hevc / OMX.hisi.video.decoder.hevc is_hw=1 lowlat=off oprate=max
transport: usb (setting auto)
resolution: 2800x1840 display=native @120 fps
target_hz: 120
real_hz: 119.9 (vsync p50 8.34 ms; display_hz 120.0)
bitrate_kbps: 60000 (setting auto)
mode: daily pacer=adaptive
content: Krita pen strokes, brush smoothing off
duration_s: 60
run: 1 of 3
claim_ok: yes (3 runs planned: quote the spread over all of them, not one run)
== end header ==
```

- `--content`, `--run K --runs N` set the hand-written fields. `an.py`, `macan.py` and `tools/soak/summarize.py`
  take `--header FILE` (a `device-smoke.sh` output, or `--header-only`) and fill what their own inputs do not know.
- **Three runs or more per condition before any claim**, on the same build and setup; report the spread over all runs
  (verify-E PF1). Do not filter to "dense seconds"; if a filter is unavoidable, say so in `content` and give the
  unfiltered numbers next to it.
- `real_hz` is the client's Choreographer vsync median, a proxy: Huawei AGP can run the panel at another rate
  (NOTES 2026-10-02 ~21:30, LOGGING T-169). `mbmon.sh` reads the panel itself. On this tablet pen, touch and
  trackpad raise the panel to 120 Hz; a 60 Hz measurement needs keyboard-driven content (PF3).
- A missing value prints `-`. `apk_sha: -` means the `app_start`/`profile` lines already rotated out of the logcat
  ring (a mode change or reconnect writes a new `ev=profile`); the settings panel "Sürüm" row shows the same SHA.

## Privacy

- Raw logs never touch the disk: `mblog.py filter` runs inside the pipe. It keeps only known stats/identity lines
  (`MB/render ev=stats`, `MB/decoder ev=stats`, host `ev=latency`, `ev=cadence`, `net ev=stats`, `app_start`,
  `profile`, `codec_start`, `stream_config`, …). Of those it keeps numeric values (`12`, `-3.5`, `7.1/7.5/9.0`, `-`)
  and a short list of identity keys checked against strict patterns (SHA, codec name, size, mode ids). Anything else
  on the line is dropped. `--events` keeps only event names; `--agp` keeps only the AGP fps number and a bare
  `touch` marker.
- The device serial is never printed (`ANDROID_SERIAL` picks a device when more than one is attached). A device that
  is not the HUAWEI tablet is refused.
- `device-smoke.sh` keeps nothing unless `--out DIR`; `--out` stores only filtered files.
- Check any output before pasting it (expect no output):

  ```bash
  grep -n -i -E 'clipboard|clip_|keycode|char=|text=|password|serial|/Users/|(^|[ =:/])[0-9]{1,3}(\.[0-9]{1,3}){3}([^0-9.]|$)' OUTPUT_FILES
  ```

  `selftest.sh` runs the same grep over outputs made from logs seeded with clipboard, key, path, address and serial
  lines.

## Recipes

Device runs happen one at a time (CLAUDE.md). None of these install, change settings, or start/stop the apps.
`adb` is `~/Library/Android/sdk/platform-tools/adb` when it is not on `PATH`.

### 1. Device smoke (build + 60 s stats)

```bash
scripts/device-smoke.sh --content "desktop, Safari scrolling" --run 1 --runs 3 --out ~/mb-measure
scripts/device-smoke.sh --header-only > ~/mb-measure/header.txt     # identity only, no window
```

- Keep the session streaming: a static screen writes no client stats (the summary then says so).
- Client stats are 10 s windows (6 per minute). For 1 s windows start the app with `--ez stats_1s true`.
- `host: instances=` must be 1 (two MateBridgeApp processes: NOTES 2026-10-04, T-224).

### 2. Tablet CPU / panel / temperature (mbmon.sh + an.py)

```bash
adb push tools/measure/mbmon.sh /data/local/tmp/mbmon.sh
adb logcat -v epoch -T 1 | python3 tools/measure/mblog.py filter --side tablet --agp > ~/mb-measure/cap.txt &
adb shell sh /data/local/tmp/mbmon.sh --seconds 60                # writes /data/local/tmp/mbmon.txt
kill %1
adb exec-out cat /data/local/tmp/mbmon.txt > ~/mb-measure/mbmon.txt
python3 tools/measure/an.py ~/mb-measure/mbmon.txt --log ~/mb-measure/cap.txt --window 10 \
  --header ~/mb-measure/header.txt --content "..." --run 1 --runs 3
```

- CPU is reported as % of one core per group (`client`, `sf` surfaceflinger, `codec` media codec services, `hal`
  composer/allocator, `adbd`, `logd`) and the system total out of `ncpu x 100` (`157/800`). `adbd` and `logd` are
  measurement overhead over USB; a long `mbmon.sh` run can also be started detached (`tools/soak/tablet-soak.sh`
  shows how) and the cable pulled.
- Panel source (`panel_src=` in the file header): `node` = `/sys/class/graphics/fb0/lcd_fps_scence` (Huawei),
  `sf` = `dumpsys SurfaceFlinger` refresh-rate (costs CPU at 1 Hz; prefer `--panel none` then), `none`.
- `an.py` log line: `recv_fps` (sum of `recv` over sum of `interval_ms`), `vsync_ms_p50`, `display_hz`, AGP
  `final lcd fps` counts and AGP touch lines.

`mbmon.txt` perf line: `ep= up= gen= cpu_total= cpu_idle= t_client= t_sf= t_codec= t_hal= t_adbd= t_logd=
f_cpu<policy>= (kHz) f_gpu= (Hz) temp_<zone>= (m°C) panel_hz=`. `gen` changes when a process group's pids
change; `an.py` takes no tick delta across it. In every sampler `-` means "could not be measured" (process absent,
node unreadable, command failed), never zero.

### 3. Mac CPU / GPU (macmon.sh + macan.py)

```bash
tools/measure/macmon.sh --interval 5 --seconds 180 --proc "Game Name" --out ~/mb-measure/mac.txt
python3 tools/measure/macan.py ~/mb-measure/mac.txt --host-log ~/Library/Logs/MateBridge/host.log --window 60 \
  --header ~/mb-measure/header.txt --content "..." --run 1 --runs 3
```

- `%CPU` comes from the second sample of `top -l 2` (the real average over the interval), `gpu_dev/ren/til` from
  `ioreg IOAccelerator` "… Utilization %". `top_other_cpu` is the busiest untracked process, without its name; name
  a process with `--proc` to track it.
- `hl_off=` is the `host.log` size at each sample; `macan.py --host-log` summarises `ev=latency`, `ev=cadence` and
  `net ev=stats` between the window's first and last offset (not across a log rotation).
- Measure the host in the same minute as the tablet; NOTES 2026-10-03 ~00:10 (Oyun 60/120) is the format to follow.

### 4. Soak

`tools/soak/README.md` (T-194).

## Not verified on the device yet

Written from NOTES and LOGGING.md, tested only offline (`selftest.sh`): the `lcd_fps_scence` node path and format,
the thermal zone names, the devfreq GPU node, `dumpsys media.resource_manager` line format (`codec_res` is a trend
count, not an exact instance count), `logcat -e` on HarmonyOS 4.3, and `run-as` fd counting. The first device run
(T-173 [device] criterion) checks them; fix the paths here if a value stays `-`.
