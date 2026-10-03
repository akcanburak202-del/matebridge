---
id: T-167
title: Add a display keep-time preference and "Sanal ekranı şimdi kaldır" to the menu
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-165, T-166]
decisions: [0020]
files:
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift
  - host-mac/Sources/MateBridgeCore/Video/DisplayKeepPolicy.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/DisplayKeepPolicyTests.swift
  - backlog/tasks/T-167-host-display-keep-menu.md
---

## Amaç

After T-165 a parked display costs almost nothing, but the keep time is still a fixed 10 s (or an env knob), and the only way to remove the display on purpose is Quit. This card gives the user control: a menu preference for how long the display stays after the tablet leaves (the decision 0020 options), a status line while it is parked, and an explicit "Sanal ekranı şimdi kaldır" action. The remove action is also the recovery path when the tablet is gone and the user, via Parsec, wants the windows back on the placeholder display.

Source: external architecture review 2026-10-03 (H04, D4); verification: docs/reviews/2026-10-03/verify-D-display.md (P-4).

Decision 0020 must be accepted by the user before work starts. Its default keep time is chosen by the user after T-166.

## Bağlam

- **Decision 0020 summary (docs/decisions/0020-virtual-display-lifetime.md, written by the orchestrator):** when a session ends, input is released, capture, encode and audio stop, and the display is parked with its identity, size and refresh rate. It is removed when the keep time expires (choices 10 s / 5 min / 30 min / until Quit), on "Sanal ekranı şimdi kaldır", when a different device or size connects, on a refresh change, or when the host quits. The honest lifetime is "host process, bounded by preference". If the keep time means wall time, the timer needs a continuous clock (verify-D additional issue 5); follow what T-165 chose.
- **Evidence (HEAD a30c769):**
  - The menu (`host-mac/Sources/MateBridgeApp/main.swift:52-93`) has status, video line, tablet settings, tablet files, accessibility hint, login item, USB mode, clipboard, logs, "Onaylı cihazları unut" and Quit. There is no keep setting, no remaining-time indicator and no remove action. Quit (`applicationWillTerminate` → `coordinator.shutdown()`, `:197-203`) is the only way to remove the display.
  - Existing preference pattern: `UserDefaults.standard` with a key, read on launch and toggled from the menu (USB mode `:190, :229`; clipboard `:194, :236`).
  - Coordinator events are a mailbox enum (`host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:16-31`: `sessionStarted`, `sessionEnded`, `tick`, `shutdown`, …). The status text reaches the menu through `coordinator.onSummary` (`main.swift:163`).
  - `DisplayLease` (`host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift`) holds the keep duration as a `let graceUs` today; it needs a setter.
- **Plan hints:**
  - `DisplayKeepPolicy` (pure Core): the option set, parse/serialise for UserDefaults, the default from decision 0020, and the precedence rule (the `MATEBRIDGE_DISPLAY_KEEP_S` env knob from T-165 still wins).
  - A keep change while parked takes effect from now: the new deadline is `now + newKeep`, never earlier than now, and "until Quit" clears the deadline.
  - The menu action is a new coordinator mailbox event (lifecycle, forced like `sessionEnded`) so it is ordered with session events. Never touch `VirtualDisplay` from the app target; `perform(lease…)` stays the only place that removes displays. Log `display_teardown reason=user`.
  - "Remove now" while a session is live: either disable/hide it (removing a watched display is not the goal) or end the session first. Choose one in *Plan* and justify it.
  - Status line while parked: "Sanal ekran bekletiliyor (mm:ss)" counting down (or "süresiz" for until Quit); refresh it from the existing 1 s tick, not a new timer.
  - LOGGING.md is not in `files:`; if `reason=user` needs documenting, write it under *Açık sorular*.
- **Serialize with:** T-145 (same file `main.swift`; chain T-145 → T-167 → T-189 → T-192). `StreamCoordinator.swift` follows T-165 (depends_on; chain T-165 → T-167 → T-187 → T-196 → T-200).
- No wire change; `docs/PROTOCOL.md` is not affected. A factory reset of this preference comes later with T-192 (host "Ayarları sıfırla"); keep the UserDefaults key in one constant so T-192 can remove it.

## Kapsam dışı

- A "recreate the display without a tablet" action (needs its own decision: only useful with Parsec watching, and it risks hiding windows on an unwatched display).
- Keeping the display on capture/encoder failure (T-200).
- Client changes.

## Kabul kriterleri

- [ ] [XCTest] `DisplayKeepPolicy`: parse, default (per decision 0020) and UserDefaults round-trip for every option; unknown stored values fall back to the default; the env knob takes precedence.
- [ ] [XCTest] A keep-time change while parked takes effect from now (deadline = now + new keep, never in the past); switching to "until Quit" while parked removes the deadline; switching back sets one.
- [ ] Menu: a keep-time submenu with the 0020 options (checked item = current), persisted across host restarts.
- [ ] Menu: "Sanal ekranı şimdi kaldır" is enabled only while a display is parked (or ends the session first, per the choice justified in *Plan*).
- [ ] Status line shows "Sanal ekran bekletiliyor (mm:ss)" while parked and disappears when the display is unparked or removed.
- [ ] [device] With the tablet away and the display parked, menu → "Sanal ekranı şimdi kaldır" (via Parsec) moves the windows back to the 1920×1080 placeholder, and host.log shows `display_teardown reason=user`.
- [ ] [device] Keep time set to 5 min: tablet screen off for 2 min, then on → image returns with `display_unparked` and windows in place.
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
