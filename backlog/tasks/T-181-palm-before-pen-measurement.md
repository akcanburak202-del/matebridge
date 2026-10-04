---
id: T-181
title: Measure palm-before-pen clicks and the touchMajor distribution
status: done
phase: 6
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - probes/input-probe/app/src/main/kotlin/dev/matebridge/probe/input/
  - backlog/tasks/T-181-palm-before-pen-measurement.md
---

## Amaç

Palm rejection already works while the pen is in range (decision 0006). One residual remains: a palm that lands *before* the pen comes into range, and is held longer than 40 ms or moves more than 16 px, goes to the Mac as a click or drag. The later pen-range release cannot undo it. This card measures how often that happens in real drawing, and whether contact size (`touchMajor`/`size`) separates palm from finger on this panel. The data decides for or against a contact-size palm filter (T-203), so nothing gets built on a guess.

Source: external architecture review 2026-10-03 (PK4, PK5); verification: docs/reviews/2026-10-03/verify-G-input.md (P-PALM measurement part, additional issue 6).

## Bağlam

**Evidence at HEAD (a30c769):**
- The palm arrives as **FINGER** from `input_mt_wrapper` (NOTES l.50), so tool type cannot reject it. The device is API 31: `FLAG_CANCELED` (API 33) and `TOOL_TYPE_PALM` are unavailable.
- Client gate (`client-android/app/src/main/kotlin/dev/matebridge/client/input/TouchTracker.kt`):
  - new finger presses, scrolls and pinches are refused while the pen is in range and for `GATE_HOLD_MS = 1200` after the last PEN message (`:412-413`, `:445`);
  - a pending or pressed finger is dropped when the pen enters range (`:186-193`), counted as `palmRejects`, which the client input stats line logs as `palm_reject=` (`input/Model.kt:201`);
  - a finger press is sent after `HOLD_MS = 40` ms or after moving more than `SLOP_PX = 16` px (`:140`, `:247`, `:429-430`). This is the residual window.
- The host gate is 1 s from receipt (`host-mac/Sources/MateBridgeCore/Input/InputStateMachine.swift`).
- The user reported palm rejection as working (T-025). There is no complaint about pre-pen clicks yet (manifest §5 Q16).
- No contact-size heuristic exists anywhere.
- The input probe (T-003) logs `size` (`probes/input-probe/app/src/main/kotlin/dev/matebridge/probe/input/EventMapper.kt:26`, `:41`) but not `touchMajor`/`touchMinor`. Add them there (and to `Records.kt`/`EventJson.kt` in the same directory) only if `size` turns out to be too coarse.

**Procedure (orchestrator; the user draws):**
1. Record the APK and host commit SHAs (`ev=app_start` from T-145/T-146, or `git rev-parse --short HEAD` of each build), the probe commit, and the HarmonyOS build.
2. **Size distribution** (input probe, no MateBridge session):
   - 50 deliberate fingertip taps and drags;
   - 50 deliberate palm rests in drawing posture (side of the hand, as when writing).
   Compute per contact the max and median `size` (and `touchMajor` if added) for finger vs palm **within the client gate's decision window**: the first 40 ms of the contact (`HOLD_MS`) or until it has moved more than 16 px (`SLOP_PX`), whichever comes first. That is the window in which the existing finger gate, and T-203's filter, decide. Also report the whole-contact max for comparison, because a palm that grows after 40 ms looks separable over the whole contact but not to the filter. Report the distributions (min/p5/median/p95/max) and the best single threshold (on the window statistic) with its false-reject and false-accept rates. The probe's local JSONL has per-sample time and position for the window cut; do not copy coordinates out of it.
3. **Palm-before-pen count** (MateBridge session over USB, 15 min of normal drawing in Krita):
   - sum the client `palm_reject=` counter;
   - count host left-button down events that are not pen strokes (a scratch Mac `CGEventTap` listener filtered to non-tablet `leftMouseDown`, timestamps only);
   - ask the user to call out any stray click they notice.
   A stray click is a non-tablet down within ~1.5 s before a pen stroke starts.
4. Write a dated NOTES entry: build IDs, both distributions, the count of palm-before-pen clicks per 15 min, and a decision for or against T-203 with the proposed threshold if "for".

Wire: none.

## Kapsam dışı

- Building any filter (T-203, gated on this card; that would amend decision 0006).
- Changes to the client app.
- Pinch or scroll policy while the pen hovers (a UX change the user has not asked for).

## Kabul kriterleri

- [ ] [device] Finger vs palm `size` distributions (and `touchMajor` if added to the probe) from ≥50 contacts each, computed within the first 40 ms or before 16 px of movement (plus the whole-contact max for comparison), with the best single threshold on the window statistic and its error rates.
- [ ] [device] Count of palm-before-pen clicks during 15 min of real drawing, next to the client `palm_reject` total.
- [ ] [doc] docs/NOTES.md has a dated entry with build IDs, the numbers above, no coordinates, and an explicit decision for or against T-203.
- [ ] If the probe was changed: the input-probe build in `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**

**Kapatıldı (2026-10-04, kullanıcı kararı):** ölçülmedi, gereksiz hâle geldi. Karar 0030/T-223 ile Çizim modunda tek parmak/avuç hiçbir şey göndermiyor (`FingerPolicy.GESTURES_ONLY`), yani kalemden önce konan avucun tıklaması çizim sırasında oluşamıyor. Günlük modda sorun görülürse yeniden açılır.
