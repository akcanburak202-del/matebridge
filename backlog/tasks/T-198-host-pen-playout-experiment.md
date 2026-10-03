---
id: T-198
title: Experimental bounded pen playout on Wi-Fi (knob, default off)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-179, T-171]
decisions: [0024]
files:
  - host-mac/Sources/MateBridgeCore/Input/PenPlayout.swift
  - host-mac/Sources/MateBridgeCore/Input/InputPipeline.swift
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - backlog/tasks/T-198-host-pen-playout-experiment.md
---

## Amaç

**Gated: start only after T-179 has recorded "kümelenme sürüyor → T-198 açılabilir (0024)" (decision rule recorded by T-179). That requires Wi-Fi pen clustering after T-111 in topology 2 (Mac Ethernet + tablet Wi-Fi), or in topology 3 (both on Wi-Fi) only if the user states that Ethernet is not an option (T-179: clustering only in topology 3 means "Mac Ethernet is the advice, not playout"). Clustering means: in ≥ 2 of 3 runs, the Mac-side inter-event median is < 1.5 ms or p95 > 8 ms (USB reference: median 2.8 ms, p95 ~4 ms), AND the user's Krita verdict with smoothing = None says Wi-Fi curves are still visibly more angular than USB. The user must also still want pen on Wi-Fi (manifest §5 Q9: "acele yok, en sona" / draws over USB); otherwise this card stays parked.**

On Wi-Fi the tablet's ~360 Hz pen samples reach the Mac in bunches (pre-T-111: median 0.5–1.1 ms, p95 ~10 ms) and the host posts each batch back to back, ignoring the per-sample `dt_us` it already receives. This experiment lets the host re-space PEN samples by their tablet timestamps with at most 12 ms added latency, only on non-loopback sessions, behind a default-off knob. It is adopted as a default only if a Wi-Fi A/B shows a line-quality gain worth the latency.

Source: external architecture review 2026-10-03 (M04, D7); verification: docs/reviews/2026-10-03/verify-G-input.md.
Decision 0024 must be accepted by the user before work starts.

## Bağlam

**Evidence (HEAD a30c769):**
- PEN carries `base_time_us` + per-sample `dt_us` (PROTOCOL §4 PEN; decoder rejects decreasing `dt`). The client fills them from `MotionEvent` event times with **1 ms resolution**, clamped monotonic, and liveness repeats use dispatch time (G add. 4: `MotionEventAdapter.kt:169,179`, `PenTracker.kt:284,406`). Expect `dt = 0` runs and ±1 ms jitter.
- The host never reads `baseTimeUs`/`dtUs`: `InputStateMachine.handlePen` loops over `batch.samples` (`InputStateMachine+Pen.swift:16-24`); `InputController.deliver` → `flush` → `CGEventPoster.post` posts the batch in one loop (`InputController.swift:177-200, 296-306`). CGEvent timestamps are never set.
- Threading: `deliver` runs inside `queue.sync` from the session queue, and blocking the session queue is the deliberate back-pressure (`InputController.swift:8-14`). The pen/scroll watchdog (500 ms, receipt time) runs on the same input queue (`:79-86, 380-388`).
- The session transport is classified at accept (`SessionTransport.usb` = loopback/adb reverse, `.network`; `UsbTunnelPlanner.swift:102-106`), but `InputController.sessionStarted(sessionID:configID:)` does not receive it (`main.swift:137-138`). Add a `transport` parameter with a default that means "off", so `InjectTest.swift:167` needs no change; `main.swift` changes by that one argument only.
- NOTES 2026-09-30 (`docs/NOTES.md:169-178`): the arrival table; NOTES lines ~210–222: no event-timing change (rate, min spacing, Krita "use tablet driver timestamps") fixed the Krita spikes, only smoothing = None did. The benefit is unproven; that is why this is an experiment.
- PLAN Aşama 5 item "Wi-Fi'de kalem örneklerini zamana yayma (host)" (`docs/PLAN.md:181`) is this card.

**Rules from decision 0024 (draft G P-M04c):**
- Knob `MATEBRIDGE_PEN_PLAYOUT_MS` (0…12, default 0 = off). Off on `.usb` sessions regardless.
- Only PEN samples are delayed. Every state boundary flushes the playout queue immediately: CONTACT 1→0, IN_RANGE→0, tool change, `RELEASE_ALL`/`BYE`/release-all for any cause, the watchdog, session end, and **any non-PEN input message** (it is processed only after the queued pen samples, so cross-message order is kept).
- Backlog over budget collapses to immediate posting; nothing waits longer than the budget. The playout queue is bounded by the budget (AGENTS.md: bounded queues only).
- Never reorder samples; pressure, position and stroke boundaries are bit-exact. No pen-up is ever delayed beyond the budget.
- CGEvent timestamp rewriting is rejected (0024 option (c)).

**Plan hints:** a `DispatchSourceTimer` on the input queue releases due samples; the session queue never waits for playout (no sleeping inside `queue.sync`). Decide in Plan whether samples are held before the state machine (watchdog anchors move by ≤ 12 ms, harmless against 500 ms) or the produced `MacEvent`s are held after it; document why. Log aggregates only (e.g. in `input_session_end`: `playout_ms=`, `playout_flushes=`, `playout_overruns=`), never coordinates. Propose the `docs/LOGGING.md` fields under *Açık sorular* (orchestrator).

**Serialize with** T-175 and T-199 (`InputController.swift` chain T-163 → T-171 → T-175 → T-198 / T-199; `InputPipeline.swift` is also edited by T-163 and T-199). `main.swift` is in the chain T-145 → T-167 → T-189 → T-192; this card touches one call there.

**Device A/B** (orchestrator + user): Krita, smoothing = None, same 6-fast-circle workload as T-179, Wi-Fi topology where T-179 found clustering, knob 0 vs 8 vs 12, ≥ 3 runs each; T-171 `input_age` p50/p95 per run and the inter-event table from T-179's receiver; USB run with the knob set must be unchanged.

Wire: none (uses existing `dt_us`).

## Kapsam dışı

- Client changes; CGEvent timestamp rewriting; smoothing or prediction.
- Making playout the default (needs the A/B result and a decision update).
- Delaying any non-PEN message.

## Kabul kriterleri

- [ ] [XCTest] Replay of a recorded trace with an injected 30 ms burst: output spacing within ±1 ms of `dt` where within budget; samples never reorder; stroke boundaries, pressure and position bit-exact.
- [ ] [XCTest] CONTACT 1→0, IN_RANGE→0, tool change, release-all and the watchdog flush immediately. A KEY or POINTER arriving behind queued pen samples is processed only after they are flushed. No pen-up waits longer than the budget.
- [ ] [XCTest] Backlog over budget collapses to immediate posting (no unbounded delay); `dt = 0` runs and 1 ms quantisation do not stall or reorder.
- [ ] [XCTest] Decision function: `.usb` → off; knob 0/absent/invalid → off; `.network` + valid knob → on.
- [ ] Existing input fuzz and safety tests pass unchanged with the knob off.
- [ ] [device] Krita Wi-Fi A/B per the procedure, results and the user's verdict in NOTES with build IDs; USB unchanged with the knob set.
- [ ] Codex review with `--high` (pen injection) run and findings resolved.
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
