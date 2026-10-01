# Pacing analysis tools

Offline tools for tablet presentation traces (`--ez pace_trace true`, pull with
`adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > trace.csv`).

- `sim.py TRACE [--hz 60|120] [--idle-ms 1000 [--refill 32]] [--q Q --L 6 --hold 2]` — replays a trace under a
  constant-playout-delay policy for several jitter quantiles and deadlines (latency p50, planned gaps, dropped, late).
  `--hz 120` selects 120 Hz rows and continuity; `--idle-ms` adds the client's idle rule (T-080); `--q` runs once.
  Reference for the client's `ConstantPlayoutPacer`: its unit test replays `trace7_120hz_excerpt.csv` and must match.
- `gaps.py TRACE` — receive-path arrival gaps vs capture gaps (late, bunched), decrypt time.
- `trace7_120hz_excerpt.csv` — 3000 frames from a 120 Hz drawing session (timing columns only, no content).
