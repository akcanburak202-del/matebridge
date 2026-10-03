---
id: T-171
title: Measure input age at injection through host PING (diagnostics only)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-152, T-163]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift
  - host-mac/Sources/MateBridgeCore/Input/InputAge.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - docs/LOGGING.md
  - backlog/tasks/T-171-host-input-age-ping.md
---

## Amaç

Nothing measures how old an input event is when the Mac injects it. The host never sends PING and ignores PONG, so it has no clock offset to the tablet, and the input timestamps on the wire are unused. After this card the host sends PING every 500 ms on an active control connection, estimates the tablet→host clock offset from PONG, and logs the age of every PEN/KEY/POINTER/SCROLL/PINCH message at delivery as per-class percentiles. Input-path latency, Wi-Fi bunching and late replays after stalls then become visible, with no wire change and no behaviour change. The data unlocks T-174's residual, T-179 and the stale-input policy (T-199).

Source: external architecture review 2026-10-03 (M04, LM3, LM8, IN8); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W3), docs/reviews/2026-10-03/verify-G-input.md (P-M04b, additional issue 3), docs/reviews/2026-10-03/coverage-audit.md (§4.3 merge).

## Bağlam

**Why no decision record:** `docs/PROTOCOL.md:567` (§6) already says "Host da aynı aralıkla gönderebilir". There is no byte, fixture or dependency change, and nothing behaves differently based on the age. The orchestrator adds at most one clarifying sentence to PROTOCOL §6 ("the host sends PING every 500 ms on the accepted control connection and uses PONG only for its own diagnostic offset estimate"). Implementers do not edit PROTOCOL.md.

**Evidence:**
- The host answers PING (`SessionMachine.swift:741-742`) but drops PONG in the "wrong direction" list (`:755-756`). It never sends PING.
- The client already answers any PING: `is Ping -> out += Action.Send(Pong(msg.seq, msg.senderTimeUs, nowUs))` (client `session/SessionMachine.kt:280`), with `nowUs = System.nanoTime()/1000` (client `SessionController.kt:325`).
- Client input times are `MotionEvent.eventTime*1000` (uptime, CLOCK_MONOTONIC, same base as `System.nanoTime`; client `input/Model.kt:10`), with **1 ms resolution** on API 31. PEN carries `base_time_us` + per-sample `dt_us`; KEY/POINTER_REL/POINTER_ABS/SCROLL/PINCH carry `time_us` (PROTOCOL §4).
- No host code reads these times (`InputStateMachine+Pen.swift:16-24` ignores `baseTimeUs`/`dtUs`; PROTOCOL §7: "mesajdaki `*_time_us` kullanılmaz").
- `InputController.deliver` takes `now = HostClock.nowUs()` on the input queue (`InputController.swift:177-200`, `now` at `:184`).
- The heartbeat tick runs every 100 ms; the `.active` branch is at `SessionMachine.swift:514-521`.

**Design (one log shape, G's):**
- **Offset estimator** (pure, `MateBridgeCore/Input/InputAge.swift`, new): mirror the client `ClockSync` (`client/stream/ClockSync.kt:14-24`): `rtt = hostNow − echo`, `offset = responder − (echo + rtt/2)`; the lowest-RTT sample of a recent window wins; a bogus echo (rtt < 0) is ignored. PONG rides the same client FIFO as input, so its RTT inflates under congestion; the min-RTT window handles that.
- **Age:** PEN sample age = `hostRecv − (base + dt − offset)`; KEY/POINTER/SCROLL/PINCH age = `hostRecv − (time_us − offset)`. Negative ages are kept and counted, not clamped (H05 lesson).
- **Histogram:** fixed-size buckets per class (pen, pointer, key, scroll incl. pinch), computed on the input queue, no allocation per sample.
- **Log:** `ev=input_age` once per second while input flows: `p50/p95/p99/max` µs per class, `n` per class, `late_250ms`, `neg`, `offset_rtt_us`, `clock_unc_us` (= best RTT / 2). Session totals go into `input_session_end`. Never keys, characters or coordinates.
- **PING timing:** emit from the `.active` branch of `tick` every 500 ms, only on an ACCEPTED **and activated** connection, i.e. after T-152's proof-first step. Never during `.proving`, `.pending` or `.awaitingHello`. Track the outstanding seq per connection; a PONG with an unknown seq or from another connection is ignored.
- **Routing:** the simplest path is for `SessionMachine` to turn a matching PONG on the active connection into a clock-sample action (or a `.deliver` of the PONG) that `SessionServer` hands to `InputController`, so the estimator lives on the input queue. `handlers.deliver` in `MateBridgeApp/main.swift` already fans every delivered message out to the input controller; if a new route would require editing `main.swift`, stop and write it in *Açık sorular*.

**Risks:**
- A PING adds ~30 bytes per 500 ms to the H→C control stream; on Wi-Fi it queues behind audio. Harmless, but note it in LOGGING.
- Any PONG from the client resets the host silence timer like other messages; the client already sends its own PINGs, so heartbeat behaviour does not change.
- 1 ms event-time resolution gives ±1 ms quantisation; USB numbers near 1–3 ms are at that floor.

**Order and hot files:**
- `SessionMachine.swift` chain T-152 → T-155 → **T-171**: T-152 is a dependency; **serialize with T-155 (same file)**.
- `SessionServer.swift` chain T-163 → **T-171** → T-186 → T-189 → T-196.
- `InputController.swift` chain T-163 → **T-171** → T-175 → T-198 / T-199.
- Codex review is required (input path), per CLAUDE.md.

## Kapsam dışı

- Acting on the age: dropping, delaying or reshaping input (stale-input policy is T-199, decision 0025; pen playout is T-198, decision 0024).
- An input `seq` or `INPUT_ACK` on the wire (deferred until after T-174).
- Client changes. Watchdog or heartbeat thresholds.
- Per-call injection timing (T-175).

## Kabul kriterleri

- [ ] [XCTest] Offset estimator: picks the min-RTT sample from the window; ignores a bogus echo; survives clock skew and a backwards jump of the client clock (fake clocks).
- [ ] [XCTest] Age per PEN sample = `hostRecv − (base + dt − offset)`; KEY/POINTER/SCROLL/PINCH `time_us` age is computed the same way. Negative ages are kept, reported in `neg` and in the distribution, not clamped.
- [ ] [XCTest] `SessionMachine` sends PING every 500 ms only on an ACCEPTED and activated connection, never while `.proving`/`.pending`/`.awaitingHello` and never before ACCEPTED. A PONG with an unknown seq or from another connection is ignored.
- [ ] [XCTest] The histogram is fixed-size; the `ev=input_age` fields are produced once per second only while input flows; session totals appear in `input_session_end`. No key, character or coordinate appears in either line.
- [ ] [doc] `docs/LOGGING.md` documents `ev=input_age`, the new `input_session_end` fields, and that ages are diagnostics with ±(RTT/2 + 1 ms) uncertainty. *Açık sorular* gives the orchestrator the one-line PROTOCOL §6 text.
- [ ] Codex review (`./scripts/codex-review.sh main task/T-171-…`) has no open findings.
- [ ] [device] USB pen drawing: pen p50 is a few ms, `late_250ms` = 0. Wi-Fi: the same 60 s workload, numbers (p50/p95/p99/max per class, `offset_rtt_us`) recorded in NOTES with build IDs.
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
