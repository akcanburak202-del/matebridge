# Soak tools (T-173, used by T-194)

Resource trends over hours and days. The samplers reuse `tools/measure/` (`mbmon.sh --soak`, `macmon.sh --soak`);
the result header and privacy rules are in `tools/measure/README.md`. Nothing here installs an app, changes a setting
or starts/stops MateBridge.

| File | What it does |
|---|---|
| `tablet-soak.sh start\|status\|stop\|pull DIR` | Copies `mbmon.sh` to `/data/local/tmp` and runs it **on the tablet**, detached (survives cable pulls and Wi-Fi periods). Every 60 s: client PSS (`dumpsys meminfo`), open fds (`run-as … ls /proc/<pid>/fd`), threads grouped by name with trailing numbers stripped (`mb-ctl-read`, `mb-video…`, `mb-audio…`, `mb-decoder…`, `Binder`, …), lines mentioning a codec in `dumpsys media.resource_manager`. A background `logcat -e` keeps only stability events. `pull` copies the numeric samples and only the event **names**, then deletes the tablet files (`--keep` keeps them). |
| `host-soak.sh --out FILE` | `macmon.sh --soak --interval 60`: MateBridgeApp RSS, open files (`lsof`), threads (`ps -M`), instance count, pid (restarts), CPU/GPU, and per-sample counts of `pipeline_retry`, `input_release`, `session_started`, `display_recreate`, `app_start`, `keyframe_request` from `host.log`. |
| `summarize.py` | Per-hour means, least-squares slopes (RSS/PSS MB/h, fds, threads per prefix, codec lines), restarts (pid changes, >1 host instance), event totals. Numbers only; the thresholds and the verdict are T-194's. |

Tablet events counted: `give_up` (decoder), `decoder_previous_stuck`, `detach_slow`, `retire_lock_slow`,
`audio_previous_slow`, `release_all`, `reconnect`, `connect_ok`, `connect_fail`, `video_lost`, `transport_migrate`,
`session_failed`, `app_start`, `codec_start`.

## Procedure (8 h day, T-194 step 3)

```bash
scripts/device-smoke.sh --content "soak baseline" > ~/mb-soak/header.txt     # baseline header, USB, session live
tools/soak/tablet-soak.sh start
nohup tools/soak/host-soak.sh --out ~/mb-soak/host-soak.txt >/dev/null 2>&1 &
# ... the working day; `tools/soak/tablet-soak.sh status` any time adb is up ...
tools/soak/tablet-soak.sh stop
kill %1                                                                         # or kill <host-soak pid>
tools/soak/tablet-soak.sh pull ~/mb-soak
python3 tools/soak/summarize.py --host ~/mb-soak/host-soak.txt --tablet ~/mb-soak/tablet-soak.txt \
  --events ~/mb-soak/tablet-events.txt --from-h 1 --header ~/mb-soak/header.txt --content "8 h real work"
```

- Compare thread and fd counts in the same state (session live, idle desktop): a mode change or a game adds threads.
- `tablet sample gaps > 3 min` in the summary shows when the tablet sampler did not run (sleep, reboot).
- NOTES gets the summary tables, not the raw sample files.
