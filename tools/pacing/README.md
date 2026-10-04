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
- `sim.py TRACE --holds [--latch]` (T-208, rules since T-220, source since T-225) — the client's presentation metric
  (`skip_pct`, `hold_*` in `render ev=present`, `HoldMeter` in `VideoStats.kt`) on a device trace, rule for rule:
  - Source (T-225): traces with a `cb_ns` column (the frame-rendered callback's `nanoTime`, last column, 0 = none) are
    judged on the callback times, like the client's `skip_pct`: a frame is decoded at `ready_ns` and shown at `cb_ns`
    (events merged by time), a frame without a callback was dropped by the compositor and is not shown (its predecessor's
    hold comes out long). The first output line says `source: callback times (cb_ns)`. Traces without `cb_ns`, and
    `--latch`, use T-220's release-time latch model described below, which is the client's `latch_skip_pct`
    diagnostic and over-counts when the release call returns within ~1 ms of the compositor deadline.
  - Content runs: every decoded row in record order; capture gaps within 1 ms of the run's first gap are one run.
  - Latch model: each released row counts at the vsync the client attributed it to. Traces from the T-220 review on have
    `latch_slot_ns` / `latch_period_ns` (last two columns: clock and grid read after the release call returned;
    a frame released at once, action `now`, has them too). For older traces the vsync is rebuilt from the
    schedule-time grid (`released_slot_ns`, or the first vsync after `release_ns + deadline_ns` when that was later);
    across a panel-rate change this can differ from the client, and a `now` row breaks the sequence.
  - Two shown frames are judged when the later one's run reaches back to the earlier one, the panel rate is the same
    (5 %), and the run gap is n periods +- 1 ms (1 <= n <= 3). A release for the same vsync as the previous one
    replaces it (never shown), so an interval is judged once the next release confirms it.
  - Hold < n short, = n exact, > n long. A frame dropped in between makes its predecessor's hold long when the
    successor kept its own slot. Each interval is grouped by its own panel rate.
  - Output: per panel rate and cadence `N intervals, exact, short, long, holds`, a last line `skip_pct (long holds,
    the client metric)`, then ready->slot p50 and path counts.

  Device check for 60 fps on 120 Hz: `120 Hz, cadence 2: ... exact >= 98%`, paths mostly `locked`.
  `python3 sim.py --holds-selftest` checks the same vector as the JVM test `PresentationMetricTest.simSelfTestVector`
  (every 10th frame replaced, one late release: `88 intervals, exact 86.4%, short 1.1%, long 12.5%`). It also checks a
  trace with the latch columns across a 120 -> 60 Hz change (`120 Hz, cadence 2: 39`, `60 Hz, cadence 1: 38`).
  Third vector (T-225): callback times regular 2 vsyncs apart while the latch columns alternate 3 and 1, one frame
  without a callback: `97 intervals, exact 99.0%, long 1.0%`, and `--latch` on the same rows `short 50% long 50%`.
- T-208 old/new replay of the integer-cadence lock: the JVM test `IntegerCadenceLockTest` (synthetic 60 fps on 120 Hz,
  uniform and two-bucket jitter, panel switches, host drift) and `traceReplayThinnedTo60FpsOldVersusNew` (`trace7` with every
  second capture = 60 fps content with real decode jitter) print old (`integerLock` off) against new
  (`cd client-android && ./gradlew testDebugUnitTest --tests '*IntegerCadenceLockTest*' -i | grep -E 'holds|trace7'`).
  In a trace a locked frame that missed its lattice slot and was shown on the next vsync has `slot_ns > lock_slot_ns`.
- `gaps.py TRACE` — receive-path arrival gaps vs capture gaps (late, bunched), decrypt time.
- `trace7_120hz_excerpt.csv` — 3000 frames from a 120 Hz drawing session (timing columns only, no content).
