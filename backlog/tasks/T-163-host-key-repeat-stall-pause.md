---
id: T-163
title: Pause host key auto-repeat while the control connection is silent
status: review
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Keyboard.swift
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine.swift
  - host-mac/Sources/MateBridgeCore/Input/InputPipeline.swift
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - backlog/tasks/T-163-host-key-repeat-stall-pause.md
  - host-mac/Sources/MateBridgeApp/main.swift  # orchestrator-approved 2026-10-03, wiring only
---

## Amaç

The host generates key auto-repeat itself and stops it only on that key's UP, another DOWN, or a release-all. If a Wi-Fi stall starts after a KEY DOWN reached the Mac but before its UP, the Mac keeps repeating until the delayed UP arrives or the 1.5 s heartbeat-silence release-all fires: up to ~18 ghost repeats with macOS defaults (1.5 s / 83 ms), so held Backspace deletes text and arrows run away. This card pauses repeat (without generating an UP) while nothing has been received on the control connection for more than 600 ms, and resumes it on the next received record if the key is still held.

Source: external architecture review 2026-10-03 (M04 (freshness), X2); verification: docs/reviews/2026-10-03/verify-G-input.md (P-KR, additional issue 1).

## Bağlam

- **Decision and protocol prose:** this amends decision 0003 (keyboard, physical keycodes) with a new repeat stop condition. The orchestrator adds a 4th host stop condition to `docs/PROTOCOL.md` §4 KEY ("Otomatik tekrar", today: UP of that key, another DOWN, release-all) and a note to `docs/decisions/0003-keyboard-physical-keycodes.md`. Implementers do not edit either file. Wire: prose only; no bytes or fixtures change.
- **Evidence (HEAD a30c769; `Core/` = `host-mac/Sources/MateBridgeCore/`):**
  - Repeat is armed on DOWN (`Core/Input/InputStateMachine+Keyboard.swift:83-85`), stopped on that key's UP (`:89`), on any other DOWN (`:76`) and on release-all (`releaseKeys`, `:108-110`).
  - `repeatKeyIfDue` (`:99-106`) emits at most one repeat per call and schedules the next a whole interval after `now`, so a late timer never bursts. It runs from `applyWatchdogs` (`Core/Input/InputStateMachine.swift:236`); `nextDeadline` includes `keyRepeat.nextAt` (`:165`); `reanchorWatchdogs` handles a backwards clock (`:216-219`).
  - Defaults: delay 500 ms, interval 83 ms (`InputStateMachine.swift:43-44`); the host passes the user's macOS values (`MateBridgeHost/Input/InputController.swift:134-139`).
  - PROTOCOL §6: the client PINGs every 500 ms; the host applies release-all after 1500 ms of control silence (`Core/Session/SessionMachine.swift:84`, `releaseSilenceUs`) and closes at 5000 ms. PROTOCOL §7 watchdogs cover pen/scroll/pinch only, not keys.
  - `InputController.deliver` (`InputController.swift:177-199`) sees only input messages (it returns early for PING and other control records) and runs under `queue.sync`. So it cannot tell that the control connection is alive; a separate activity signal from the session layer is needed. Control records are decoded in `SessionServer.swift` (`machine.received(...)`, `:1237`), and delivered at `:1473-1474`.
- **Plan hints:**
  - Add a `lastControlActivity` input to the Core state machine (or pipeline) and a pure rule: no repeat while `now − lastControlActivity > 600 ms` (PING 500 ms + margin). Do not generate an UP; do not change the held-key set.
  - Update the timestamp for every decoded control record (PING included) of the connection whose input is delivered (the active session) only, from `SessionServer` via a `noteControlActivity` hook. `SessionServer.swift:1237` decodes records of every connection, including pending or unauthenticated ones and a T-096 migration candidate on USB while the Wi-Fi session is stalled; counting those would keep ghost repeat alive in exactly the stall case. Pass it without `queue.sync` re-entry (an atomic, or ride on `deliver`).
  - **Ordering detail:** watchdogs run before each input message is handled (PROTOCOL §7 "önce kapanış, sonra mesaj"). When the delayed KEY UP itself ends the stall, the pause check must use the activity time from *before* that record, so no repeat fires ahead of the UP.
  - While paused, `nextDeadline` must not keep the timer spinning on an overdue repeat. Re-arm the watchdog on the paused → active edge (e.g. a cheap `queue.async { rearmWatchdog() }` only on that edge).
  - After resume the existing one-per-call rule must still prevent a burst; the next repeat is at least one interval after resume.
  - Core `SessionMachine` already tracks `lastReceive` per connection, but `SessionMachine.swift` is outside `files:` (it is in the T-152 → T-155 → T-171 chain). Do not edit it here.
  - A client-side keepalive for held keys is the alternative; it needs protocol semantics and stays out of scope (the orchestrator mentions it in the 0003 note).
- **Safety (AGENTS.md):** UP, release-all and heartbeat release must still stop repeat and release the key exactly as today. Never drop a key-up. Keycodes may appear only at `debug` level; never key characters.
- **Serialize with:** `SessionServer.swift` chain T-163 → T-171 → T-186/T-189 → T-196 (T-186 and T-189 in either order) and `InputController.swift` chain T-163 → T-171 → T-175 → T-198 / T-199; this card is the head of both.
- **Review:** input-state change, so the orchestrator runs `./scripts/codex-review.sh`.

## Kapsam dışı

- Client keepalives for held keys (protocol semantics).
- Stale-input policy for clicks, keys and pen after stalls (decision 0025, T-199).
- Changing the 1.5 s / 5 s heartbeat thresholds.
- PROTOCOL.md and decision 0003 text (orchestrator).

## Kabul kriterleri

- [ ] [XCTest, fake clock] With a key held and repeat armed, no repeat is emitted while `now − lastControlActivity > 600 ms`.
- [ ] [XCTest] Repeat resumes after new activity if the key is still held; the first repeat after resume comes at least one interval later (no burst).
- [ ] [XCTest] A delayed KEY UP that arrives after a > 600 ms silence produces the key-up and zero repeats before it.
- [ ] [XCTest] UP, another DOWN, release-all and the heartbeat-silence release still stop repeat and release the key exactly as before; existing keyboard, fuzz and safety tests pass unchanged.
- [ ] [XCTest] While paused, `nextDeadline` does not return an overdue repeat deadline (no busy timer).
- [ ] Only records of the active session's control connection update `lastControlActivity`; records from pending, unauthenticated or migration-candidate connections do not. An XCTest (if the filter is in Core) or the Handoff code path shows the filter.
- [ ] [device] Wi-Fi only: hold Backspace (in a scratch text field) and toggle the tablet's Wi-Fi off for ~2 s, then on. The Mac shows at most ~7 repeats after the stall begins (≤ 600 ms of repeat at the macOS interval; today up to ~18). Count the deleted characters, and record `repeats=` from `input_session_end`. No key stays stuck after reconnect. Repeat on a normal hold (no stall) feels unchanged. Handoff states that resume-after-stall is covered only by XCTest (a sub-1.5 s stall is not reproducible by toggling Wi-Fi; the 2 s toggle crosses the 1.5 s heartbeat release).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **Core (`InputStateMachine`, `+Keyboard`)**: `Configuration.keyRepeatStallPauseUs = 600_000`; `lastControlActivity: UInt64?` (nil = no information yet: never paused, so every existing test behaves as today). Pure rule `isKeyRepeatPaused(at:)`: repeat armed, activity known and `now − lastControlActivity > 600 ms`. `repeatKeyIfDue` emits nothing while paused (no UP, held-key set untouched); `nextDeadline` leaves the repeat out while paused (no overdue deadline, no busy timer). `noteControlActivity(at:) -> Bool`: true on the paused → active edge, and then the next repeat moves to `max(nextAt, at + interval)` (no burst). `reanchorWatchdogs` re-anchors an activity time ahead of `now` (backwards clock). `handle` never updates activity itself: the caller notes it AFTER the record, so a delayed KEY UP is checked against the activity from before it.
2. **`InputPipeline`**: forwards `noteControlActivity(at:)` to the current machine (false without a session).
3. **`InputController`**: `noteControlActivity(at:)` callable from the session queue without `queue.sync`: stores the time under an `NSLock`; only when the gap to the previous stored time exceeds the pause threshold it does one `queue.async` that pushes the time into the pipeline and re-arms the watchdog. Every queue entry point (`deliver` before `handle`, watchdog, poll) first pushes the stored time; `sessionStarted` counts as activity.
4. **`SessionServer`**: new `Handlers.controlActivity(receivedUs)`, called in `receiveControlBytes` after `machine.received(...)` was applied, only when `id == activeControl` (pending, unauthenticated, proving/takeover candidates are never `activeControl`).
5. **Tests** (`Tests/MateBridgeCoreTests/Input/KeyRepeatStallTests.swift`): pause, resume without burst, delayed UP with zero repeats, UP / other DOWN / release-all / heartbeat release while paused, `nextDeadline` while paused, pipeline forwarding.

Risk: the app's handler wiring lives in `host-mac/Sources/MateBridgeApp/main.swift`, which is not in `files:` (see Açık sorular).

## Handoff

- **Commit:** `376c9cb` (implementation + tests; plan in `eed91eb`), `11a9d2c` (merge of `main`, no conflicts), `3f8ee0c` (app wiring), branch `task/T-163-host-key-repeat-stall-pause`.
- **Dokunulan dosyalar:** `Core/Input/InputStateMachine.swift`, `Core/Input/InputStateMachine+Keyboard.swift`, `Core/Input/InputPipeline.swift`, `MateBridgeHost/Input/InputController.swift`, `MateBridgeHost/Session/SessionServer.swift`, new `Tests/MateBridgeCoreTests/Input/KeyRepeatStallTests.swift` (16 tests: STALL-1..7, SPIPE-1..4 incl. a 40-seed fuzz), `MateBridgeApp/main.swift` (one line of wiring, orchestrator-approved 2026-10-03).
- **Ne yapıldı:**
  - Core: `Configuration.keyRepeatStallPauseUs = 600_000`; `lastControlActivity` (nil = no information: never pauses, so `InjectTest` and every existing test behave as before); `isKeyRepeatPaused(at:)` (strictly `> 600 ms`); `repeatKeyIfDue` emits nothing while paused (no UP, `heldKeys` untouched); `nextDeadline` leaves a paused repeat out (no overdue deadline); `noteControlActivity(at:) -> Bool` returns true on the paused → active edge and moves the next repeat to `max(nextAt, at + interval)`; `reanchorWatchdogs` re-anchors an activity time ahead of `now`. `handle` never updates activity, so the caller's order (handle, then note) makes a delayed KEY UP see the silence from before it.
  - Pipeline: `noteControlActivity(at:)` forwards (false without a session).
  - `InputController.noteControlActivity(at:)`: no `queue.sync`; the time goes into an `NSLock`-protected field. Every queue entry point (`deliver` before `handle`, watchdog timer, 1 s poll) pushes it into the pipeline first. Only a note that follows a gap > 600 ms does one `queue.async { pushActivity(); rearmWatchdog() }` (the paused → active edge). `sessionStarted` clears the stored time (nothing of the previous session carries over).
  - `SessionServer`: new `Handlers.controlActivity(receivedUs)`, called in `receiveControlBytes` right after `apply(machine.received(...))` and only `if id == activeControl`. **Filter code path:** `activeControl` is set only by `.sessionStarted` and cleared by `.sessionEnded`; pending (approval), unauthenticated (awaiting HELLO / lookup) and takeover/migration candidates (`.proving`) never are `activeControl`, so their records are not counted. A candidate that wins the takeover becomes active in that record's own `apply` (old session ended, fresh machine), so counting it from then on is correct.
- **Varsayımlar:** `SessionServer.nowUs()` is `HostClock.nowUs()` (same clock as the input queue). The threshold the controller uses for the wake-up edge is the default config value (600 ms), the same as the machine's.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - Wiring done: `main.swift` sets `handlers.controlActivity = { input.noteControlActivity(at: $0) }` next to `handlers.releaseInput`.
  - [device] Wi-Fi only, hold Backspace in a scratch text field, toggle tablet Wi-Fi off ~2 s, then on. Expect at most ~7 repeats after the stall begins (today up to ~18); record `repeats=` from `input_session_end`; no stuck key after reconnect; a normal hold (no stall) feels unchanged.
  - Resume-after-stall is covered only by XCTest (STALL-2, STALL-2b, SPIPE-4): a sub-1.5 s stall is not reproducible by toggling Wi-Fi (the 2 s toggle crosses the 1.5 s heartbeat release).
  - Not run: no app launch, no real CGEvents, no device.
- **Açık sorular:**
  1. ~~Scope: `main.swift` wiring outside `files:`~~ resolved: the orchestrator approved adding it (2026-10-03); done in `3f8ee0c`.
  2. PROTOCOL §4 KEY "Otomatik tekrar" prose (4th stop condition, as a pause rather than a stop: the key stays held and repeat resumes one interval after the next received record) and the 0003 note are for the orchestrator.
