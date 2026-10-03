---
id: T-165
title: Park the virtual display after a session ends (no capture or encode while parked)
status: in-progress
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/DisplayLeaseTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/IntegrationTests.swift
  - docs/LOGGING.md
  - backlog/tasks/T-165-host-park-virtual-display.md
---

## Amaç

When a session ends, the host keeps capture (ScreenCaptureKit) and the encoder (VideoToolbox) running for the whole 10 s grace, draining frames into nothing, and then removes the virtual display. This card "parks" the display instead: on session end, capture and encode stop at once and only the `VirtualDisplay` object stays alive for the keep window; when the same device returns, a fresh pipeline is built on the parked display. Idle cost during the keep window drops to about zero, which makes a longer keep time cheap (the policy itself is decision 0020 and T-167; the default stays 10 s here).

Source: external architecture review 2026-10-03 (H04, A1, F2, D4); verification: docs/reviews/2026-10-03/verify-D-display.md (P-2).

## Bağlam

- **Evidence (HEAD a30c769; `HH/` = `host-mac/Sources/MateBridgeHost/`, `HC/` = `host-mac/Sources/MateBridgeCore/`):**
  - `HC/Video/DisplayLease.swift:9`: `defaultGraceUs = 10_000_000`. `sessionEnded(now:)` (`:59-61`) only changes state to `.grace`; `tick` (`:63-67`) returns `.teardown` at the deadline; `displayLost()` (`:70`) and `shutdown()` (`:72-75`). Actions today: `.teardown`, `.create`, `.reuse`, `.reconfigure`.
  - `HH/Session/StreamCoordinator.swift:392-407` `onSessionEnded`: releases the display-sleep assertion (`:396`), resets the display rate (`:397`), stops the consumer, calls `lease.sessionEnded`, then `startDrain()` (`:403-405`; drain task at `:720-724`) and logs `display_grace_started`. The 1 s tick (`:290-292`) drives `lease.tick`.
  - `resetDisplayRate()` at session end also undoes panel-rate decimation, so moving content is encoded at full stream fps for up to 10 s (T-014 handoff, `backlog/tasks/T-014-host-integration.md:51`, already named this waste).
  - The hand-over already exists: `VideoPipeline.stopKeepingDisplay()` (`HH/Video/VideoPipeline.swift:250`) and `init(reusing:)` from T-049; `restartPipeline` (`StreamCoordinator.swift:564-574`) uses it and was device-tested.
  - `obtainDisplay` (`VideoPipeline.swift:134-143`) recreates on a refresh mismatch: invalidate, sleep 700 ms, create.
  - Device evidence that the 10 s teardown hurts: NOTES 2026-10-02 13:45 (tablet screen off ~56 s → `display_grace_started seconds=10` → `display_teardown`); window layout disturbance on recreate (NOTES 2026-09-30 line 206).
- **Plan hints:**
  - `onSessionEnded` calls `pipeline.stopKeepingDisplay()` instead of `startDrain()`, stores the result in a coordinator field (e.g. `parked: VirtualDisplay?`), and the next same-device session calls `createPipeline(settings:, reusing: parked)`.
  - **Existing `DisplayLease` tests outside `files:`:** `StreamPrefsTests.swift:148-150` (`sessionEnded` then `[.reuse]`) and `BitratePrefsTests.swift:83,98` assert today's results. Same-device return from park keeps returning `[.reuse]`; the coordinator knows the display is parked (its `parked` field) and builds the pipeline with `reusing:`. Those call sites must compile and pass unchanged (mark a new `sessionEnded` return value `@discardableResult` if needed).
  - `final class DisplayLeaseTests` already exists in `IntegrationTests.swift:39`. Extend that class, or name the new file's class `DisplayParkTests`; do not redeclare it.
  - Keep `perform(lease…)` the single place that creates or removes displays. `onPipelineFailed` with only a parked display: nothing to do (no pipeline). `onShutdown` must invalidate `parked`.
  - If `CGDisplayIsOnline(parked.displayID)` is false (display sleep may take it offline), create a new display instead. Public CG only: `HH/VirtualDisplay.swift` stays the only private-API file.
  - Static-screen guard (T-028 class): the new pipeline needs SCK's first frame before `prepareForNewConsumer` can force a keyframe. That is the same as the reconfigure path, which works on device, but verify it explicitly (acceptance).
  - Keep-time knob: `MATEBRIDGE_DISPLAY_KEEP_S`, parsed by a pure Core function (10…86400, otherwise 10). T-167 later adds the menu preference; the env knob keeps winning.
  - Clock: `HostClock` is mach absolute time (`HH/Session/HostClock.swift:8-10`) and does not advance in system sleep. Fine for 10 s; if the keep time is meant as wall time, use a continuous clock (`mach_continuous_time`) (verify-D additional issue 5). State the choice in *Plan*.
  - Low-severity notes, **not** fixed here: `VirtualDisplay.selectMode` blocks a cooperative thread with `Thread.sleep(0.1)` up to 20 times (`HH/VirtualDisplay.swift:134-146`, D add. 3); the recreate path has no fallback if creation fails (`VideoPipeline.swift:136-142`, D add. 4).
  - The display-sleep assertion stays released while parked (D add. 6); T-166 measures what that does.
- **Serialize with:** `StreamCoordinator.swift` chain T-165 → T-167 → T-187 → T-196 → T-200; this card is the head. `VideoPipeline.swift` is also in T-162's `files:` (conditional) and later in T-176/T-177/T-187/T-200: do not run in parallel with a card that is editing it.
- No wire change; `docs/PROTOCOL.md` is not affected. The client is unchanged.

## Kapsam dışı

- The menu preference and "Sanal ekranı şimdi kaldır" (T-167).
- Changing the 10 s default (decision 0020, after T-166).
- Keeping the display on capture/encoder failure (T-200, gated on T-166).
- Fixing D add. 3 / add. 4; any client change.

## Kabul kriterleri

- [ ] [XCTest] `DisplayLease`: `sessionEnded` yields a park action (e.g. `.park`); `tick` past the deadline yields `.teardown` exactly once; same device + `sameDisplay` → `[.reuse]` as today (the coordinator reuses the parked display); refresh mismatch → recreate; different device or size → teardown + create; `shutdown` while parked → teardown; `displayLost` while parked → idle. Existing 10 s default semantics and tests are kept, including `StreamPrefsTests`/`BitratePrefsTests` unchanged.
- [ ] [XCTest] Pure parse of `MATEBRIDGE_DISPLAY_KEEP_S`: 10…86400 accepted, anything else (missing, empty, non-numeric, out of range) → 10.
- [ ] Log lines `display_parked keep_s=`, `display_unparked`, `display_teardown reason=keep_expired|device_changed|size_changed|shutdown`, documented in `docs/LOGGING.md`.
- [ ] While parked there is no SCK stream and no VT session (no `startDrain`; Handoff shows the code path).
- [ ] [device] Tablet screen off → host log `display_parked`; MateBridgeApp CPU and GPU in Activity Monitor drop to idle while parked.
- [ ] [device] Reconnect within the window shows an image within 1 s, also on a static screen, 5/5 (T-028 regression guard), with `display_unparked` and no `display_created`.
- [ ] [device] Akıcı (120 Hz) → Netlik (60 Hz) chosen on the tablet while parked (disconnected) recreates the display exactly once on reconnect (`display_recreate reason=refresh_change`).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **`DisplayLease` (Core):** `.grace` state → `.parked`. New `Action.park`. `sessionEnded(now:)` becomes `@discardableResult -> [Action]` and returns `[.park]` only from `.active`, so the old call sites (`StreamPrefsTests`, `BitratePrefsTests`) compile and pass unchanged. `.teardown` keeps no payload (existing tests compare `[.teardown, .create(s)]`). Instead, `lastTeardownReason` (`keepExpired`, `deviceChanged`, `sizeChanged`, `shutdown`; `logName` = snake_case) is set whenever a call returns `.teardown`. T-167 adds `user`. `isParked` is added, and `isInGrace` stays as an alias. Pure parse: `DisplayLease.keepSeconds(_:)` for `MATEBRIDGE_DISPLAY_KEEP_S` (trimmed integer, 10…86400, otherwise 10) and `keepUs(env:)`.
2. **`VideoPipeline`:** `obtainDisplay` reuses an inherited display only when its refresh matches **and** `CGDisplayIsOnline` is true (public CG). Otherwise it uses the existing invalidate + 700 ms + create path. New `isOnline(_:)` helper and `displayWasReused` flag, so the coordinator can log `display_created` only for a new display.
3. **`StreamCoordinator`:** new field `parked: (display, sinceUs)?`.
   - `onSessionEnded` → `perform(lease.sessionEnded(now:))`. `.park` stops the consumer, calls `pipeline.stopKeepingDisplay()`, and stores the display. There is no `startDrain`, so no SCK stream and no VT session (the T-162 teardown awaits `enc.shutdown()`). Log `display_parked keep_s=`. If there is no pipeline or display, it calls `lease.displayLost()`.
   - `.reuse` / `.reconfigure(s)` with no pipeline but a parked display → **unpark**: `createPipeline(settings:, reusing: parked)`, log `display_unparked parked_ms=` (+ `display_recreate reason=refresh_change|offline` when VideoPipeline has to recreate). `.reuse` takes its settings from `session.settings`.
   - `.teardown` destroys the pipeline and invalidates `parked`, logging `display_teardown reason=<lease.lastTeardownReason>`.
   - `onShutdown` runs `perform(lease.shutdown())` (reason=shutdown) and then also drops `parked` defensively.
   - `onPipelineFailed` is unchanged: with only a parked display, `pipeline == nil` and it returns.
   - `onVideoAttached` hands any leftover parked display to the rebuild.
   - `perform` stays the only place that creates or removes displays.
4. **Clock choice:** the keep time is **wall time**. The lease runs on a continuous clock (`clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)`, which keeps counting during system sleep, same as `mach_continuous_time`) in `sessionEnded` and `tick` only. So after a long system sleep, the parked display is removed on the first tick after wake. Prefs gate and stats stay on `HostClock`.
5. **Keep-time knob:** `StreamCoordinator()` without `graceUs` reads `MATEBRIDGE_DISPLAY_KEEP_S` (default 10 s, unchanged).
6. **Input:** unchanged. `main.swift` still calls `input.sessionEnded()` (release-all) on the same session-end hook. Parking only touches video.
7. **Tests:** extend `DisplayLeaseTests` in `IntegrationTests.swift` (park/teardown-once/reuse/refresh/device/size/shutdown/displayLost/reasons) and add `DisplayLeaseTests.swift` with `DisplayParkTests` (keep parse). Update `docs/LOGGING.md`.
8. **Risks:** if `CGDisplayIsOnline` is false for a healthy virtual display, every unpark and restart would recreate (device check). Takeover (end and start at once) now rebuilds capture and encode on the same display instead of reusing a running pipeline.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
