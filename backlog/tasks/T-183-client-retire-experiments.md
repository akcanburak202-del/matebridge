---
id: T-183
title: Retire concluded client experiments (perf hint, rvote, cpd, …; Wi-Fi knobs kept)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-182, T-168]
decisions: [0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FramePacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/PerfHint.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AndroidPerfHint.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/RefreshVote.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/ConstantPlayoutPacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/OperatingRate.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/StatsFormat.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/PerfHintTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/RefreshVoteTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/ConstantPlayoutPacerTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/LockRecenterTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/AdaptivePacerTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/VsyncIdleTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/security/RecordOpenTest.kt
  - tools/pacing/README.md
  - backlog/tasks/T-183-client-retire-experiments.md
---

## Amaç

The daily video path still carries the branches of several concluded experiments:
- the PerformanceHint hooks in both decoder threads;
- a hidden-API refresh-vote driver;
- a constant-playout pacer the user rejected;
- an operating-rate switch the decoder ignores;
- an inflight limit that measured worse;
- the inconclusive keep_jitter/recenter switches;
- a one-shot crypto bench.

Removing them, without changing any default behaviour, makes `VideoRenderer` and `MainActivity` smaller and easier to reason about before the next lifecycle work. The Wi-Fi TOS/`wifi_ll` knobs are explicitly **kept** until T-127 re-measures them.

Source: external architecture review 2026-10-03 (L02); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-C1, L02 inventory rows 3, 6, 9, 10, 12, 13, 16), amended by coverage audit K4 (docs/reviews/2026-10-03/coverage-audit.md).
Decision 0026 must be accepted by the user before work starts.

## Bağlam

**What goes.** Row numbers refer to the inventory in T-182 / `docs/KNOBS.md`. Paths are relative to `client-android/app/src/main/kotlin/dev/matebridge/client/`.
- **perf hint** (row 13, T-079; HarmonyOS returns no hint session, NOTES.md:440):
  - `MainActivity.setupPerfHint` (`MainActivity.kt:345-353`);
  - `video/PerfHint.kt`, `video/AndroidPerfHint.kt`;
  - hooks in `VideoRenderer.kt:99-100`, `:331-337`, `:402-407`, `:473-476`;
  - `SessionController.kt:124`, `:811` (reader thread);
  - `PerfHintTest`.
- **refresh vote** (row 16, T-140, negative; uses `Class.forName("android.view.DynamicRefreshRateHelper")`):
  - `MainActivity.kt:294-308`, `:431`, `:1790`;
  - `video/RefreshVote.kt` (including `RefreshVoteDriver`);
  - `RefreshVoteTest`.
- **cpd pacer** (row 10, T-080):
  - `MainActivity.kt:400-405`;
  - `VideoRenderer.kt:82-83`, `:134`, `:377-380`, `:560`;
  - `video/ConstantPlayoutPacer.kt`;
  - `ConstantPlayoutPacerTest`, and the cpd cases in `VsyncIdleTest.kt:205-230`.
  - Keep `tools/pacing/sim.py` and `tools/pacing/trace7_120hz_excerpt.csv`, which `SparseFrameNoHoldTest` also uses. Update the one README line that says the cpd unit test replays the trace.
- **oprate** (row 3, T-052; the HiSilicon decoder ignores `KEY_OPERATING_RATE`, NOTES.md:315):
  - remove the `--ei oprate` extra (`MainActivity.kt:373`);
  - keep today's default (rate = stream fps, `VideoRenderer.kt:284`) unless you show it is a no-op. Simplify `video/OperatingRate.kt` and the `OperatingRateTest` class inside `AdaptivePacerTest.kt:325-331` accordingly.
- **inflight limit** (row 6, T-057, measured worse, NOTES.md:342):
  - `MainActivity.kt:223`, `:385`, `:1160`, `:1288`;
  - the occupancy gate in `VideoRenderer.kt:447-452` and the `maxInFlight` field (`VideoRenderer.kt:89`).
  - Remove only the `maxInFlight`/`inflightLimit` plumbing and that gate. `InFlightGauge` (`video/SlotReleaser.kt:130ff`: occupancy, `in_codec_p95`) and the `inflight_limit=` field of `StatsFormat.presentFields` stay, with the caller passing a constant 0 (`VideoRenderer.kt:165`). So `PresentationSchedulingTest` (`InFlightGaugeTest` `:92-135`, `presentFieldsFormat` `:138-145`) passes unchanged, and `SlotReleaser.kt` is not edited. Deleting `InFlightGauge.canQueue` is a follow-up; note it under *Açık sorular*.
- **keep_jitter/recenter** (row 9, T-067 inconclusive, closed by T-182):
  - `MainActivity.kt:397-398`;
  - the `VsyncClock` fields in `video/FramePacer.kt` and the branches in `video/AdaptivePacer.kt`;
  - the `recenters=` field plumbing in `stream/StatsFormat.kt:51-56` (it prints only when non-null);
  - `LockRecenterTest`.
- **crypto bench** (row 12, T-076, concluded):
  - `MainActivity.kt:408-410`;
  - `security/Records.kt:56-121` (bench only; keep `stampOpens`, which `pace_trace` uses);
  - `benchReportsInitAndFinalSplitPerSize` in `client-android/app/src/test/kotlin/dev/matebridge/client/security/RecordOpenTest.kt:58-62`, which calls `Records.bench()`. Only that bench test changes in this file.

**What stays (do not touch):**
- `VsyncClock` (`video/FramePacer.kt:18`) is on the daily path.
- `FramePacer` itself stays while `--ei jitter 1|2` is debug-only. Delete the buffer 1–2 branch only if decision 0026 retires it (T-182 open point).
- `--ez pace_trace`, `stats_1s` and `stall_diag` stay (diagnostics).
- **Out of scope by audit K4:** `session/WifiKnobs.kt`, `tos_ctl`/`tos_video`/`wifi_ll`, `WifiLockHolder` and the `WAKE_LOCK` permission stay as they are until T-127 reports. T-197 later adds a knob to `WifiKnobs.kt`.
- The GL path (T-184) and the `dev` gate and `net_bench` move (T-185) are separate cards.

**Removed log fields:** `ev=display_timing` (`MainActivity.kt:1282-1288`) carries `keep_jitter=`, `recenter=`, `pacer=`, `cpd_q_permille=`, `cpd_hold_us=` and `inflight=`, all of which go. List every removed `display_timing`/`present` field under *Açık sorular* for the orchestrator's `docs/LOGGING.md` edit.

**Field names:** T-168 renames `shown=` → `released=` and `latency_us` → `cap_dec_*`, keeping aliases for one release. Compare with those names or their aliases. `ev=present`/`stats` fields read by `tools/pacing` must keep their names.

**Implementer check:** confirm the actual file names under `video/` and `session/` before starting; the paths above were checked at a30c769.

**Serialization:**
- `MainActivity.kt` chain: … T-168 → T-169 → T-183 → T-184 → T-185 → T-191. Serialize with T-169 (same file, not a dependency). Earlier chain cards (T-146, T-151, T-153, T-159, T-160) must not be in progress either.
- `VideoRenderer.kt` chain: T-158 → … → T-168 → T-183 → T-184.
- `RecordOpenTest.kt`: **serialize with T-150 (same file)**. T-150 lists `client-android/app/src/test/kotlin/dev/matebridge/client/security/`, and T-150 is also an earlier `MainActivity.kt` editor.

Wire: none.

## Kapsam dışı

- Any default-behaviour change.
- `WifiKnobs.kt` and the Wi-Fi TOS/`wifi_ll`/WifiLock knobs (audit K4).
- The GL path (T-184); the `dev` gate, `ev=profile` and moving `net_bench` (T-185).
- `jitter`, `lead_us`, `deadline_us` and other debug-only extras.

## Kabul kriterleri

- [ ] [JVM] Default-path tests pass unchanged: `PacingTest`, `AdaptivePacerTest` (except the reduced `OperatingRateTest` class), `SparseFrameNoHoldTest`, `PresentationSchedulingTest`, `NewestFrameShownTest`, `PhaseLockTest`, `VsyncIdleTest` (minus the cpd cases).
- [ ] [JVM] `PerfHintTest`, `RefreshVoteTest`, `ConstantPlayoutPacerTest` and `LockRecenterTest` are deleted together with their code, and `RecordOpenTest` loses only its bench test. No main or test source references `PerfHint`, `RefreshVote`, `ConstantPlayoutPacer`, `CpdConfig`, `keepJitter`, `recenter`, `inflightLimit`, `maxInFlight` or the crypto bench (`Records.bench`) (grep in Handoff). Exception: the `PaceTrace.PATHS` names (`video/PaceTrace.kt:113`, which contain "recenter" and "cpd") stay, so the `pace_trace` CSV path codes that `tools/pacing` reads keep their index.
- [ ] [doc] `tools/pacing/trace7_120hz_excerpt.csv` and `sim.py` are kept. The fields read by `tools/pacing` keep their names (or the T-168 aliases). The README no longer mentions the deleted test.
- [ ] [doc] `WifiKnobs.kt`, `WifiKnobsTest`, `WifiLockHolder` and the `WAKE_LOCK` permission are untouched (diff shows no change).
- [ ] [doc] *Açık sorular* lists the removed `ev=display_timing`/`present` fields for the orchestrator's LOGGING.md edit.
- [ ] [device] Akıcı 120 and Oyun 120 for 2 min each over USB, compared with NOTES 2026-10-03 using T-168's names (`cap_dec_*`, `released=`) or their aliases: comparable latency and released/shown counts, no `detach_slow`, no new error lines. Launching with a removed extra (e.g. `--ez perf_hint true`) has no effect and does not crash.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
