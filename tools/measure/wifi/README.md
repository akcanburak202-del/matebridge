# Wi-Fi run kit (T-127)

- `wload.swift`: deterministic workload (40 s cycle: 20 s full-screen text scroll at 60 fps, 10 s full-screen switch every 2 s, 10 s static). Opens a borderless window on the Mac's main display: run only with the user's OK.
- `tone.py`: 320 s melody so the audio path carries sound during a run.
- `run_wifi.sh NAME [SECONDS]`: one run; writes `~/.cache/matebridge-tools/data/wifi-runs/NAME.{start,end,host.log}`.
- `an2.py NAME...`: summary table (control/video srtt, tablet-reported cap_dec, drops, retx, idr; tablet underruns/skip/fps when `NAME.tablet.log` exists).
- Tablet logs while the cable is out: start before unplugging
  `adb shell "setsid nohup sh -c 'logcat -T 1 -v threadtime -f /data/local/tmp/t127.log -r 8192 -n 20' >/dev/null 2>&1 </dev/null &"`,
  pull later and slice by the `.start`/`.end` times (grep ` MB/`).
- Host env for runs: `open --env MATEBRIDGE_SENDQ_LOG=1 --env MATEBRIDGE_LAT_TRACE=1 build/MateBridge.app`.
