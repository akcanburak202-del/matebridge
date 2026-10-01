# Pacing analysis tools

Offline tools for tablet presentation traces (`--ez pace_trace true`, pull with
`adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > trace.csv`).

- `sim.py TRACE` — replays a 60 Hz trace under a constant-playout-delay policy for several jitter quantiles and
  deadlines (latency p50, planned gaps, dropped, late). `sed`-adapt the period filter for 120 Hz (see NOTES).
- `gaps.py TRACE` — receive-path arrival gaps vs capture gaps (late, bunched), decrypt time.
- `trace7_120hz_excerpt.csv` — 3000 frames from a 120 Hz drawing session (timing columns only, no content).
