---
id: T-199
title: Apply the stale-input policy on the host
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-171, T-175]
decisions: [0025]
files:
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine.swift
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Pen.swift
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Pointer.swift
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Keyboard.swift
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Scroll.swift
  - host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Pinch.swift
  - host-mac/Sources/MateBridgeCore/Input/InputPipeline.swift
  - host-mac/Sources/MateBridgeCore/Input/InputAge.swift
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - backlog/tasks/T-199-host-stale-input-policy.md
---

## Amaç

**Gated: start only after (1) a recorded Wi-Fi run made with T-171 merged shows `max` > T_stale (300 ms) in `ev=input_age` for pen, pointer or key, with `clock_unc_us` p95 ≤ 30 ms in the same seconds (`late_250ms` > 0 alone is not enough: it counts ages above 250 ms). That run is the T-127/T-179 data (input_age recorded by T-127/T-179, including `clock_unc_us`), or a dedicated run of this card's device scenario (a ~3 s tablet Wi-Fi toggle while typing and tapping) on the current build, which needs no code. T-180's "Wi-Fi off mid-stroke" row records only `input_release`/`owed` and the close time, so it does not count; and (2) the user has accepted decision 0025 with T_stale set from that data (manifest §5 Q10). If no run ever shows input older than T_stale, this card stays parked.**

After a Wi-Fi stall of 1.5–5 s, input already in the tablet's kernel socket buffer still arrives complete and is replayed late: clicks, key presses and whole strokes land seconds after the user made them, past the release-all latch. This card applies decision 0025 on the host: input older than T_stale has its new presses ignored (together with their matching releases), hover and relative motion collapse to the newest state, and releases are always applied. The user gains no "ghost" clicks or keystrokes after a stall, without ever losing a release.

Source: external architecture review 2026-10-03 (M04); verification: docs/reviews/2026-10-03/verify-G-input.md.
Decision 0025 must be accepted by the user before work starts.

## Bağlam

**Evidence (HEAD a30c769):**
- The host ignores every message `*_time_us` today; PROTOCOL §7 says so explicitly (`docs/PROTOCOL.md:597`, "mesajdaki `*_time_us` kullanılmaz"). Watchdogs use receipt time.
- PROTOCOL §4 "Kabul edilen davranış" (`docs/PROTOCOL.md:300`) names the 1 s client queue as the late-input bound, but bytes already in the client kernel buffer have no age limit (client control socket sets only `tcpNoDelay`, `SessionController.kt:641`; `SendQueue` checks age at offer only). The real bound is the host's 5 s silence close (§6, `docs/PROTOCOL.md:565-570`). T-172 corrects that bound text; this card adds the policy.
- Age source: T-171 adds `InputAge.swift` (offset estimator from host PING/PONG, min-RTT window) and computes per-message age on the input queue: PEN `hostRecv − (base + dt − offset)`, KEY/POINTER/SCROLL/PINCH from `time_us`. Clocks are CLOCK_MONOTONIC on the tablet with 1 ms resolution.
- Existing rules that make an ignored press's release inert: "Basılı olmayan tuş için UP da yok sayılır" (`docs/PROTOCOL.md:325`); BEGAN-less CHANGED/ENDED are ignored for SCROLL/PINCH (`:374, :422`); the pointer owner and pen latch rules (§4, §7).
- `InputController.deliver` samples `now` and the environment, then calls `pipeline.handle(message, now:, environment:)` (`InputController.swift:177-200`); the age must reach the pipeline from here (or from `InputAge` held by the pipeline; decide in Plan).

**Policy (decision 0025, draft G P-M04d):** for age > T_stale (initially 300 ms; final value from T-171 data):
- hover PEN and POINTER_REL motion collapse to the newest state;
- new presses are ignored together with their matching releases: PEN `STROKE_START`, POINTER button-down edges, KEY DOWN, SCROLL/PINCH BEGAN;
- every release of an **applied** press is always applied (AGENTS.md: never drop an up event);
- the policy is off (fail-open) while the offset estimate is untrustworthy (uncertainty above a bound, or no estimate yet).

**Risks to settle in Plan:**
- PEN: ignoring `STROKE_START` alone is not enough. PROTOCOL §4 lets mid-stroke contact samples after a watchdog close start a new stroke (`docs/PROTOCOL.md:298`), so the stale stroke's later contact samples must be treated as not-a-stroke until its pen-up, even if they become fresh mid-way; state the chosen rule and test it.
- An offset error turns legitimate input into "stale". Fail-open, and never act on a single sample near the threshold if the uncertainty band overlaps it.
- POINTER: `buttons` is a level mask, not an edge (`docs/PROTOCOL.md:339`, `:342`, `:354`; the host derives down/up by comparing with the previous state). A button whose down edge was ignored as stale stays latched as ignored until a message clears the bit, or until release-all. Later fresh messages with the bit set do not press it. Otherwise the next fresh message with the bit still set becomes a new down edge in the middle of the drag (the same partial-stroke problem as PEN).
- Interaction with the release-all latch and the 1 s palm gate (`InputStateMachine.swift:40, 140-144`).
- Logging: counts only (e.g. `stale_ignored_presses=`, `stale_collapsed=` in `input_session_end`), never keys, characters or coordinates. Propose the `docs/LOGGING.md` fields under *Açık sorular* (orchestrator).

**Serialize with** T-198 (same `InputController.swift` / `InputPipeline.swift`; chain T-163 → T-171 → T-175 → T-198 / T-199). T-175 is a dependency for the same reason.

**PROTOCOL prose (orchestrator, not the implementer):** §4 "Kabul edilen davranış" (`:300`) and §7 (`:597`) describe the stale policy and that the host now uses `*_time_us` for staleness only (watchdogs stay on receipt time). No bytes or fixtures change; `gen.py --check` stays green.

Wire: prose-only.

## Kapsam dışı

- Client-side keepalives for held keys (rejected in 0025).
- Measuring the age (T-171) or changing the offset estimator beyond reading its trust flag.
- Pen playout (T-198); key auto-repeat pause (T-163).

## Kabul kriterleri

- [ ] [XCTest] With age > T_stale and a trusted offset: hover PEN and POINTER_REL collapse to the newest state; a stale KEY DOWN, button-down, `STROKE_START`, SCROLL BEGAN and PINCH BEGAN are ignored, and their matching releases are inert.
- [ ] [XCTest] Every release of an **applied** press is still applied when it arrives stale (KEY UP, button-up, pen-up, SCROLL/PINCH ENDED); no held state remains after the sequence.
- [ ] [XCTest] A stale stroke whose later samples turn fresh mid-stroke follows the rule chosen in Plan (no partial stroke unless that is the documented choice).
- [ ] [XCTest] A stale button-down followed by fresh POINTER messages with the bit still set never presses; the message that clears the bit (or release-all) clears the latch, and a later fresh down presses normally.
- [ ] [XCTest] Untrustworthy or missing offset → policy off, behaviour identical to today.
- [ ] [XCTest] Ages just below T_stale and negative ages (clock noise) are treated as fresh.
- [ ] Existing input fuzz tests (`InputFuzzTests`, `KeyboardFuzzTests`) and `SafetyTests` pass; extend fuzzing with random ages and assert "no held key/button/contact after release-all".
- [ ] Logs carry counts only; no keys, characters or coordinates.
- [ ] [device] Wi-Fi, a text editor and Krita open: block tablet traffic for ~3 s (toggle tablet Wi-Fi) while typing and tapping. After traffic resumes, no keystroke or click older than T_stale lands, `stale_ignored_presses` > 0, no stuck key/button/contact, and the same test on USB with no stall shows `stale_ignored_presses=0`. Result in NOTES with build IDs.
- [ ] Codex review with `--high` (input state) run and findings resolved.
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
