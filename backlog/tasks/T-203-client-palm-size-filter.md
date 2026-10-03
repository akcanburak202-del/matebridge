---
id: T-203
title: Contact-size palm filter
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-181]
decisions: [0006]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/TouchTracker.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/MotionEventAdapter.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/Model.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/
  - backlog/tasks/T-203-client-palm-size-filter.md
---

## Amaç

**Gated: start only after T-181 records in docs/NOTES.md that (1) palm-before-pen clicks actually happen in real drawing (at least one host click per drawing session that the user identifies as a palm, or the user reports them, manifest §5 Q16), and (2) the distributions of each contact's max `size`/`touchMajor` within its first 40 ms (`HOLD_MS`), or until it moves 16 px (`SLOP_PX`), separate (the per-contact early-window statistic recorded by T-181; whole-contact max/median does not count, because a palm that grows after 40 ms looks separable there but not to the filter): there is a threshold X where ≥ 95 % of palm contacts are above X and ≤ 2 % of deliberate single-finger taps and drags are above X. If either fails, this card stays parked. The orchestrator then records the decision 0006 amendment with the chosen X.**

A palm that lands before the pen comes into range and stays more than 40 ms (or moves more than 16 px) is sent to the Mac as a click or drag; the later pen-range release cannot undo it. On this device the palm arrives as an ordinary FINGER contact, so tool type cannot reject it. If T-181 shows contact size separates palm from finger, a size gate on new single-finger presses closes this residual without touching the pen path.

Source: external architecture review 2026-10-03 (PK4, PK5); verification: docs/reviews/2026-10-03/verify-G-input.md.
The decision 0006 amendment (contact-size palm filter) must be accepted by the user before work starts.

## Bağlam

**Evidence (HEAD a30c769):**
- Palm reports as FINGER from `input_mt_wrapper` (`docs/NOTES.md:50`). API 31 / targetSdk 31: no FLAG_CANCELED (API 33), TOOL_TYPE_PALM never seen (G PK4).
- Existing gate (decision 0006 §2): new finger presses, scrolls and pinches are refused while the pen is in range and for `GATE_HOLD_MS` = 1200 ms after the last PEN message (`TouchTracker.kt:412-413, 445`); a pending or pressed finger is force-released when the pen enters range (`onPenRangeBegan`, `TouchTracker.kt:186-193`); refusals count `palm_reject` (`Model.kt:156, 201`). The host has its own 1 s gate (`InputStateMachine.swift:40`). "Parmak dokunmasını tamamen kapat" exists (`setDisabled`, `TouchTracker.kt:196-199`).
- Residual: a single finger in `PENDING` is pressed after `HOLD_MS` = 40 ms (`TouchTracker.kt:140, 429`) or after moving more than `SLOP_PX` = 16 px (`:247, 430`), before any pen is in range.
- Contact size is not carried today: `Finger(id, x, y)` (`Model.kt:136`) is built in `MotionEventAdapter.kt:113, 196` without `getTouchMajor`/`getSize`.

**Plan hints (G P-PALM):**
- Add `touchMajor` (or `size`, whichever T-181 found separating) to `Finger`, filled in `MotionEventAdapter` (keep the adapter free of logic; the decision lives in `TouchTracker`).
- Gate: a single-finger `PENDING` contact whose size exceeds X does not become a press (count it as `palm_reject`). Decide in Plan how size growth after DOWN is handled (a palm often lands small and grows within the first frames; checking the max size during `HOLD_MS` is the likely rule).
- Two-finger gestures (pinch/scroll) keep their current behaviour unless T-181 shows palms trigger them; state the choice.
- **Releases stay unconditional:** a finger already pressed is always released normally, whatever its size later becomes (AGENTS.md: never drop an up event).
- No coordinates or sizes in per-event logs; per-second counters only.
- X is a `const val` with a comment naming the T-181 NOTES entry.

Wire: none.

## Kapsam dışı

- API 33 features; changes to the pen path or to the 1.2 s / 1 s gates.
- Host-side changes.
- A "drawing" finger profile or the finger-off default (already decision 0006 §2).

## Kabul kriterleri

- [ ] [JVM] A single-finger contact with size > X is never pressed (neither by `HOLD_MS` nor by slop), and increments `palmRejects`; one with size ≤ X behaves exactly as today.
- [ ] [JVM] A contact that grows above X during `HOLD_MS` follows the rule chosen in Plan; a contact that grows above X after it was pressed is still released normally (no lost up).
- [ ] [JVM] Pinch and scroll behaviour with large contacts matches the documented choice; existing `TouchTrackerTest`, `PinchTest`, `InputFuzzTest` and `InputHardeningTest` pass.
- [ ] [JVM] Fuzz with random sizes: no pointer is left pressed after the final UP/CANCEL.
- [ ] [device] With the pen out of range, rest a palm on the screen 20 times: palm clicks on the Mac drop to ≤ 1 (compare with T-181's count); 20 deliberate finger taps and 10 drags all still work. Result in NOTES with build IDs.
- [ ] Codex review (input state) run and findings resolved.
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
