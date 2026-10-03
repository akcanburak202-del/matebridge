---
id: T-200
title: Keep a healthy display when capture or the encoder fails
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-165, T-166]
decisions: [0020]
files:
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/PipelineFailurePolicy.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/PipelineFailurePolicyTests.swift
  - backlog/tasks/T-200-host-display-keep-on-failure.md
---

## Amaç

**Gated: start only after T-166 has recorded "T-200 = go" in docs/NOTES.md, which requires its step 2 to show that a parked virtual display survives display sleep: during and after `pmset displaysleepnow`, `CGDisplayIsOnline` stays true for the `v0x4d42/m0x1` display and window placement is unchanged after the tablet reconnects. If T-166 shows the display goes offline in display sleep, the orchestrator either narrows this card to non-display failures (SCK -3817 user stop, encoder errors) or closes it; record which in this card before work starts.**

Today any capture or encoder failure destroys the virtual display immediately, even when the display itself is fine, so windows migrate to the 1920×1080 placeholder and Krita's panels shift. With this card a failure whose display is still online hands the display back to the coordinator (like the parked display of T-165) and the rebuild reuses it, so a transient capture error (for example stopping capture from the menu-bar recording indicator) no longer disturbs the window layout.

Source: external architecture review 2026-10-03 (H04, F2); verification: docs/reviews/2026-10-03/verify-D-display.md.
Decision 0020 must be accepted by the user before work starts.

## Bağlam

**Evidence (HEAD a30c769):**
- `VideoPipeline` doc: on its own failure the pipeline "stops itself (closing the virtual display and `frames`)" (`VideoPipeline.swift:22-24`). `fail(_:)` (`:291-302`) → `stop()` → `teardown()` (`:279-289`) → `disp?.invalidate()`.
- The hand-over path already exists: `stopKeepingDisplay()` (`:250-253`) → `teardown(keepingDisplay: true)` returns the live display (T-049). T-165 builds parking on it.
- `StreamCoordinator.onPipelineFailed` (`:501-530`) sets `pipeline = nil` ("the pipeline already closed its display"), calls `lease.displayLost()`, and rebuilds once after ~1 s **only while a session is live** (`:513`). During grace/parking nothing rebuilds.
- Failure classification exists: `DisplayWaker.reason(for:)` maps `VirtualDisplayError.creationFailed` and SCStream error codes (`DisplayWaker.swift:32-37`, `DisplayWakeReason` in `DisplayWakePolicy.swift`). The mailbox event is `.pipelineFailed(id:message:wake:)` (`StreamCoordinator.swift:26, 295, 581`).
- Device history: SCK -3817 when capture was stopped from the menu-bar indicator; recovery took 1.2 s via `pipeline_retry` → `display_created` (a new display) (`docs/NOTES.md:196`). SCK -3815 on display sleep, and `CGVirtualDisplay initWithDescriptor` returns nil while displays sleep (`docs/NOTES.md:470, 474`).
- D additional issue 2: T-132's "display reused after wake" assumption is probably false because of this path; T-166 step 3 settles it.

**Plan hints (D P-5):**
- Pure policy in Core: `PipelineFailurePolicy.decide(errorKind, displayOnline) -> keep | invalidate`. Error kinds come from the existing classification (capture source lost / user stopped / encoder error / unknown). `displayOnline` is read with public CG (`CGDisplayIsOnline(display.displayID)`) in `VideoPipeline`; `VirtualDisplay.swift` stays the only private-API file and is not edited.
- `onFailure` carries the kept display through the mailbox (e.g. `.pipelineFailed(…, display:)`). Ownership stays single: once the pipeline hands the display over it no longer holds it; the coordinator either reuses it (live session: rebuild on it) or parks it (T-165 `parked`), and invalidates it on shutdown.
- If the kept display is offline at rebuild time, fall back to create (same rule as T-165).
- Keep `perform(lease…)` the single place that creates or removes displays.
- Log: `pipeline_failed … display=kept|invalidated` (extend the existing line; propose the field for `docs/LOGGING.md` under *Açık sorular*).

**Serialize with** T-196 (`StreamCoordinator.swift` chain T-165 → T-167 → T-187 → T-196 → T-200). `VideoPipeline.swift` is also edited by T-165, T-176, T-177, T-187 and T-196.

Wire: none.

## Kapsam dışı

- Parking itself and the keep time (T-165, T-167); the 0020 default (user, after T-166).
- A crash supervisor (T-202); a fallback when `CGVirtualDisplay` is unavailable (not carded, D P-9).
- Any client change.

## Kabul kriterleri

- [ ] [XCTest] `PipelineFailurePolicy`: every error kind × `displayOnline` true/false gives the documented keep/invalidate result (table test); unknown errors invalidate.
- [ ] [XCTest] (or a pure coordinator-state test) A kept display has exactly one owner after the failure, is reused by the rebuild, and is invalidated exactly once on shutdown.
- [ ] [device] Stop capture from the menu-bar recording indicator (SCK -3817) during a session: video recovers, the log shows `display=kept` and no `display_created`, and Krita windows and panels do not move.
- [ ] [device] Display sleep (`pmset displaysleepnow`) with a session live, then wake: behaviour matches T-166's recorded result (kept if the display stayed online, otherwise invalidated and recreated as today). Results in NOTES with build IDs.
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
