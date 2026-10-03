# Pacing analysis tools

Offline tools for tablet presentation traces (`--ez pace_trace true`, pull with
`adb exec-out run-as dev.matebridge.client cat cache/pace_trace.csv > trace.csv`).

- `sim.py TRACE [--hz 60|120] [--idle-ms 1000 [--refill 32]] [--q Q --L 6 --hold 2]` — replays a trace under a
  constant-playout-delay policy for several jitter quantiles and deadlines (latency p50, planned gaps, dropped, late).
  `--hz 120` selects 120 Hz rows and continuity; `--idle-ms` adds the client's idle rule (T-080); `--q` runs once.
  The client's `ConstantPlayoutPacer` (T-080) that mirrored it was retired in T-183 (decision 0026); git history keeps it.
- T-115 old/new replay of the adaptive pacer (phase lock, lone frames without hold): the JVM test
  `SparseFrameNoHoldTest.traceReplayOldVersusNew` replays `trace7_120hz_excerpt.csv` through `AdaptivePacer` with
  `sparseEarly` off and on and prints lone-frame latency and continuous gaps/drops
  (`cd client-android && ./gradlew testDebugUnitTest --tests '*SparseFrameNoHoldTest*' -i | grep trace7`).
  Path names in pace traces: `early_sparse` / `early_first` = lone frame on the earliest slot (`acquire_ns` is the slot
  the old hold would have chosen), `warmup` = lock re-acquired on a thin jitter history.
- `sim.py TRACE --holds` (T-208) — hold distribution of the released frames from a device trace: per panel rate and
  content cadence n, the share of frames held exactly n vsyncs (planned `released_slot_ns`, not the compositor's),
  plus ready->slot p50 and path counts. The cadence comes from the original capture sequence (every decoded frame,
  also replaced/discarded ones: all gaps between two visible frames n periods +- 1 ms), so a dropped frame counts as a
  hold of 2n, not as a skipped interval. Device check for 60 fps on 120 Hz: `120 Hz, cadence 2: ... exact >= 98%`,
  paths mostly `locked`. `python3 sim.py --holds-selftest` checks this on a synthetic trace (every 10th frame
  replaced: `89 intervals, exact 88.8%, holds 2:88.8% 4:11.2%`).
- T-208 old/new replay of the integer-cadence lock: the JVM test `IntegerCadenceLockTest` (synthetic 60 fps on 120 Hz,
  uniform and two-bucket jitter, panel switches, host drift) and `traceReplayThinnedTo60FpsOldVersusNew` (`trace7` with every
  second capture = 60 fps content with real decode jitter) print old (`integerLock` off) against new
  (`cd client-android && ./gradlew testDebugUnitTest --tests '*IntegerCadenceLockTest*' -i | grep -E 'holds|trace7'`).
  In a trace a locked frame that missed its lattice slot and was shown on the next vsync has `slot_ns > lock_slot_ns`.
- `gaps.py TRACE` — receive-path arrival gaps vs capture gaps (late, bunched), decrypt time.
- `trace7_120hz_excerpt.csv` — 3000 frames from a 120 Hz drawing session (timing columns only, no content).
