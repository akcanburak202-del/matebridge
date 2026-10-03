---
id: T-171
title: Measure input age at injection through host PING (diagnostics only)
status: review
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
- `SessionServer.swift` chain T-163 → **T-171** → T-186/T-189 → T-196 (T-186 and T-189 in either order).
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

1. **Core `Input/InputAge.swift` (new, pure):**
   - `ClockOffsetEstimator`: ring of the last 8 PONG samples. `rtt = recv − echo`; `offset = responder − (echo + rtt/2)` (client − host); the min-RTT sample wins; `rtt < 0` is ignored. Wrapping `Int64` arithmetic, so client-chosen values never trap.
   - `AgeHistogram`: fixed log-linear buckets (16 sub-buckets per power of two, ≤ 6.25 % error, overflow bucket), a mirror set for negative ages, exact `max`, count. Storage is allocated once; `reset()` zeroes in place.
   - `InputAgeTracker`: classes pen (per sample, `base + dt`), pointer (REL + ABS), key, scroll (SCROLL + PINCH). Age = `recv − (t − offset)`, negative ages kept and counted (`neg`), `late_250ms`, `no_offset` (input before the first PONG). A 1 s window opens at the first sample; `takeReport(now:)` returns the `ev=input_age` fields once the window is ≥ 1 s old, otherwise nil. Session totals feed `input_session_end`.
2. **Core `SessionMachine`:** `Configuration.hostPingIntervalUs = 500_000`. Per active connection: `nextAt`, next seq, ≤ 4 outstanding `(seq, sentAt)`. The `.active` branch of `tick` sends `PING(seq, now)` when due (first tick after `start`, then every 500 ms, no burst after a late tick). Never in `.awaitingHello` / `.lookingUp` / `.pending` / `.proving`. A PONG on the active connection whose seq is outstanding and whose echo equals the PING's time becomes `.deliver(id, .pong)`; anything else is ignored.
3. **Host `InputController`:** `deliver(.pong)` feeds the estimator (time taken before the queue hop); input messages are recorded with the `now` that `deliver` already takes. `input_age` logged from `deliver` and from the 1 s poll (so the last window of a burst is reported). `sessionStarted` resets the tracker; `input_session_end` gets the totals. Nothing about applying input changes.
4. **`SessionServer`:** routing already exists (`.deliver` → `handlers.deliver` → `input.deliver`); only the handler doc changes. No `main.swift` edit.
5. **Tests:** `Tests/MateBridgeCoreTests/Input/InputAgeTests.swift` (estimator, ages, histogram, report cadence, privacy) and `Tests/MateBridgeCoreTests/Session/HostPingTests.swift` (PING cadence and gating, PONG matching). Existing tests that tick an active session get the new PING actions filtered or expected.
6. **`docs/LOGGING.md`:** `ev=input_age`, new `input_session_end` fields, uncertainty, PING bytes.

Risks: existing session tests compare exact `tick` output (adjust within `Tests/.../Session/` and `Input/`); tests outside `files:` that break are a scope stop.

## Handoff

- **Commit:** `dd6c281` (implementation, tests, LOGGING), plan in `4081a53`, branch `task/T-171-host-input-age-ping`.
- **Dokunulan dosyalar:** new `Core/Input/InputAge.swift`, `Core/Session/SessionMachine.swift`, `MateBridgeHost/Input/InputController.swift`, `MateBridgeHost/Session/SessionServer.swift`, new `Tests/MateBridgeCoreTests/Input/InputAgeTests.swift` (EST-1..6, AGE-1..4, HIST-1..3, REP-1..3), new `Tests/MateBridgeCoreTests/Session/HostPingTests.swift` (PING-1..7, PONG-1..4), `docs/LOGGING.md` (new section "Girdi yaşı"). `main.swift` was not touched.
- **Ne yapıldı:**
  - Core `InputAge.swift`:
    - `ClockOffsetEstimator`: ring of 8. `rtt = recv − echo`, `offset = responder − (echo + rtt/2)` (client − host). The min-RTT sample wins, and `rtt < 0` is ignored.
    - `AgeHistogram`: 449 buckets per sign, 16 sub-buckets per power of two, ≤ 6.25 % error, overflow above 2^31 µs, a mirror set for negatives and an exact `max`. Allocated once; recording and `reset` never allocate.
    - `InputAgeTracker`: classes pen (per sample) / pointer (REL+ABS) / key / scroll (SCROLL+PINCH). It counts `late_250ms`, `neg` and `no_offset`, keeps a 1 s window (`takeReport`) and session totals (`sessionFields`, `age_` prefix plus `age_pongs`).
    - All client-supplied arithmetic wraps, so hostile values never trap (EST-6).
  - `SessionMachine`:
    - `Configuration.hostPingIntervalUs` (nil in Core), `defaultHostPingIntervalUs = 500_000`, `maxOutstandingPings = 4`.
    - `start()` arms the per-connection PING state, so it only exists after ACCEPTED and activation (T-152 proof / pairing persisted).
    - The `.active` branch of `tick` sends `PING(seq, now)` when due: the first tick after activation, then every 500 ms, at most one per tick, none in the tick that ends the session.
    - On the active connection, a PONG with an outstanding seq **and** the matching echo becomes `.deliver(id, .pong)` and clears that PING and every older one. Any other PONG (unknown seq, wrong echo, another or a pending connection) is ignored, as before.
  - `SessionServer` sets the interval to 500 ms. Routing reuses `.deliver` → `handlers.deliver` → `input.deliver`; the coordinator, clipboard and files consumers ignore PONG.
  - `InputController`:
    - `deliver(.pong)` takes the time before the queue hop and feeds the estimator.
    - Input messages are recorded with the `now` that `deliver` already takes, **after** `pipeline.handle`. The age is never read by the input path.
    - `ev=input_age` is written from `deliver` and from the 1 s poll. At session end the half window is written and the totals are appended to `input_session_end`.
    - `sessionStarted` resets the tracker.
- **Varsayımlar:**
  - The PING default is **off** in Core `SessionMachine.Configuration` and on in `SessionServer`. With it on in Core, five existing tests that compare whole `tick` results would break, one of them outside `files:` (`Tests/.../Crypto/KeychainAsyncTests.swift`). HostPingTests turn it on explicitly; PING-3 pins the default.
  - The card says "XCTest"; the project's tests use Swift Testing, so the new tests do too.
  - Age is measured at delivery on the input queue (queue wait included), not at the session-queue decode.
  - PEN_GESTURE is not aged (not in the card's class list).
  - The window for `ev=input_age` opens with the first sample, including `no_offset` samples, so input before the first PONG is visible as `no_offset`.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - No device test. Not run: the app, a real tablet, CGEvent posting.
  - That the client answers a host PING with a PONG on its `nanoTime/1000` clock (from code reading only, client `SessionMachine.kt:280`). On the device, look for `input_age` lines with `offset_rtt_us` ≠ `none`, and `age_pongs` > 0 in `input_session_end`.
  - USB pen drawing: pen p50 a few ms, `late_250ms=0`, `neg` ≈ 0. A large `neg` would mean the time bases differ (eventTime vs nanoTime) or the offset is wrong.
  - Wi-Fi: the same 60 s workload. Record p50/p95/p99/max per class plus `offset_rtt_us` in NOTES with build IDs.
  - Check that the host PING does not disturb the client: no change in heartbeat, the video/audio path or client logs.
- **Açık sorular:**
  - PROTOCOL §6, one sentence for the orchestrator: "Host, kabul edilip etkinleşmiş (ACCEPTED + ilk doğrulanmış kayıt) kontrol bağlantısına 500 ms'de bir PING gönderir; PONG'u yalnız kendi tanı amaçlı saat farkı tahmini için kullanır (girdi yaşı, T-171), davranış buna bağlı değildir."
  - Codex review (`./scripts/codex-review.sh main task/T-171-host-input-age-ping`) is required by the card and has not been run (orchestrator).
