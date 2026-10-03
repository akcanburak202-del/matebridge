---
id: T-166
title: Measure parked-display behaviour across sleep, lock and long outages
status: todo
phase: 6
owner: user
depends_on: [T-165, T-147]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-166-parked-display-measurement.md
---

## Amaç

Decision 0020 (virtual display lifetime) hinges on one unknown: does a retained `CGVirtualDisplay` with no capture running keep its identity and window placement through display sleep, system sleep, screen lock and long tablet outages, and can the second access path (Parsec) still use the Mac while it is parked? Nobody has measured this. This card runs a fixed procedure on the real Mac and tablet using T-165's parked display, so the user can pick the 0020 default keep time from evidence and the orchestrator can decide whether T-200 (keep the display on capture/encoder failure) is feasible.

Source: external architecture review 2026-10-03 (X7, H04); verification: docs/reviews/2026-10-03/verify-D-display.md (P-3, additional issues 2 and 6).

## Bağlam

- **Owner:** the user runs the physical steps; the orchestrator prepares the build, starts the host with the knob, collects logs and writes the NOTES entry. Device tests one at a time (CLAUDE.md).
- **Why T-147 first:** steps 2–4 deliberately leave the Mac without the tablet image. The recovery runbook and known-good version pair from T-147 must be in place and rehearsed, so the user can always get the Mac back (headless 1920×1080 placeholder plus Parsec).
- **What is known (HEAD a30c769):**
  - A new display cannot be created while the displays sleep (`initWithDescriptor` returns nil, NOTES 2026-10-01 ~14:10 / T-040); SCK loses the display during display sleep (-3815) and macOS shows the 1920×1080 placeholder.
  - Today any capture or encoder failure invalidates the display at once (`host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:279-301`), and nothing rebuilds it during grace (`StreamCoordinator.swift:513`). T-132's assumption that the display is reused after wake inside the grace window was never confirmed; the NOTES 2026-10-02 15:47 log (`wake_display` right after `session_started`) fits a fresh create (verify-D additional issue 2).
  - The display-sleep assertion is released at session end (`StreamCoordinator.swift:396`), so a parked display meets macOS idle display sleep after the user's timeout (verify-D additional issue 6).
  - `HostClock` is mach absolute time; a keep timer does not advance during system sleep unless T-165 chose a continuous clock (check its Handoff).
- **Procedure** (host started with `MATEBRIDGE_DISPLAY_KEEP_S=3600`; Krita plus 2 other windows arranged on the tablet display; note panel positions with a screenshot via Parsec or `screencapture` before each step):
  1. **Screen off:** tablet screen off for 30 s, back on; then off for 5 min, back on. Expect `display_parked` then `display_unparked`. Record window and panel positions (unchanged?) and the time to first image.
  2. **Display sleep while parked:** tablet screen off (parked), then on the Mac `pmset displaysleepnow`, wait 60 s, wake the Mac. Check `CGDisplayIsOnline` (or `system_profiler SPDisplaysDataType`) for the `v0x4d42/m0x1` virtual display during and after sleep; then reconnect the tablet and record placement and whether host.log shows `display_unparked` or a new `display_created`.
  3. **System sleep while parked:** `pmset sleepnow` (expect the T-132 BYE), wake via the tablet (T-134). Same checks. Grep host.log for `display_reused|display_created|display_create_failed` after `session_started`; this settles verify-D additional issue 2.
  4. **Parsec while parked:** switch the tablet to Parsec (MateBridge goes to the background, the session ends and the display parks). Can Parsec see and control the parked virtual display, or only the placeholder? Is the Mac usable?
  5. **Idle cost:** 5 min parked: MateBridgeApp CPU, GPU (Activity Monitor) and RSS.
- **Outputs the orchestrator turns into decisions:** the 0020 default keep time (10 s / 5 min / 30 min / until Quit; open question 2 for the user), the T-200 go/no-go (does the display survive display sleep?), and whether 0020 needs a "revisit" note (macOS takes virtual displays offline anyway).

## Kapsam dışı

- Any code change. Failures become new cards.
- Choosing the keep-time UI (T-167).

## Kabul kriterleri

- [ ] [device][doc] A dated docs/NOTES.md entry with host and client build IDs and the result of each of the five steps (positions unchanged yes/no, time to first image, `CGDisplayIsOnline` values, `display_*` log lines seen, Parsec behaviour, idle CPU/GPU/RSS). Any step not run is marked "not run" with a reason.
- [ ] [doc] The user's choice of the 0020 default keep time is recorded in NOTES (the orchestrator updates decision 0020).
- [ ] [doc] T-200 go/no-go is recorded with its reason (display survives display sleep: yes/no).

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
