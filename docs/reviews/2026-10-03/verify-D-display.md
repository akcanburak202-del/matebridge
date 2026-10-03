# Verify D — Virtual display lifetime, private API, headless recovery, sleep

Scope: H04, M06, SE5, D1, D4, X7, X13, A1 (DisplayOwner part), A6, PF5 (the mode-switch part), F2 (the display-lifetime part), F5 (the second-access-path part), W4 ("Mac session" row).
HEAD = a30c769. All line numbers below are at HEAD.

## Short answers to the orchestrator's specific questions

1. **What triggers display teardown, and how soon.**
   - **Grace expiry.** Any control-session end calls `StreamCoordinator.onSessionEnded` (StreamCoordinator.swift:392-407). That covers tablet BYE, a socket drop, takeover failure, host-sleep BYE and the mailbox-overflow `endSessions`. It calls `lease.sessionEnded(now:)`, which starts a 10 s grace period (DisplayLease.swift:9, 59-61). A 1 s tick (StreamCoordinator.swift:162-166, 290-292) calls `lease.tick`, which returns `.teardown` once `now >= deadline` (DisplayLease.swift:63-67). The display therefore goes away **10–11 s of awake time** after the session ends. `HostClock` is `CMClockGetHostTimeClock`, i.e. mach absolute time (HostClock.swift:8-10), which does not advance during system sleep.
   - **A different device or display size at reconnect** gives `[.teardown, .create]` (DisplayLease.swift:42-45).
   - **A refresh-rate change (60↔120)** recreates the display. See Q3.
   - **Any capture or encoder failure** destroys the display immediately, with no grace. `VideoPipeline.fail` → `stop()` → `teardown()` → `disp?.invalidate()` (VideoPipeline.swift:22-24, 279-301). The coordinator then calls `lease.displayLost()` (StreamCoordinator.swift:501-509). It rebuilds once after 1 s, but **only while a session is live** (StreamCoordinator.swift:513-530). During grace there is no rebuild. The review missed this trigger.
   - **Quit, SIGINT/TERM/HUP, or a crash.** `applicationWillTerminate` → `coordinator.shutdown()` (main.swift:97-104, 196-203). On a crash the OS removes the display with the process, because the `CGVirtualDisplay` object is process-owned (VirtualDisplay.swift:12-13).
2. **Does capture/encode keep running during grace?** Yes. `onSessionEnded` calls `startDrain()`, a task that pulls and discards encoded frames (StreamCoordinator.swift:403-405, 719-724). The SCK stream and the VT session keep running. The cost depends on screen activity: SCK delivers only changed frames (NOTES 2026-09-29 T-011: "SCK yalnızca ekran değişince kare veriyor"). `resetDisplayRate()` at session end (StreamCoordinator.swift:397, 362-367) also undoes the panel-rate decimation, so moving content is encoded at the full stream fps for up to 10 s. This was acknowledged in the T-014 handoff (backlog/tasks/T-014-host-integration.md:51: "Kopma sırasında boru hattı 10 sn boşuna kodluyor… yakalama duraklatılabilir, ama durağan ekranda bayat keyframe riski var").
3. **Does an fps/mode change recreate the display?** Only when `displayRefreshHz` changes. `StreamPrefsPolicy.applying` sets `displayRefreshHz = fps >= 120 ? fps : defaultRefreshHz` (StreamPrefsPolicy.swift:49). `restartPipeline` → `stopKeepingDisplay()` → the new pipeline's `obtainDisplay()` keeps the display if the rate matches. Otherwise it invalidates the display, sleeps 700 ms and creates a new one (VideoPipeline.swift:129-143; StreamCoordinator.swift:562-574, log `display_recreate reason=refresh_change`).
   - Client modes (StreamMode.kt:11-19): Netlik 60, Akıcı 120, Performans 120@750, Oyun 120 (120@660), Oyun 60.
   - **Recreate:** any move between {Netlik, Oyun 60} and {Akıcı, Performans, Oyun 120}.
   - **Display kept, but capture and encoder restart and the video connection is reset with a new `config_id`:** Akıcı↔Performans↔Oyun 120, Netlik↔Oyun 60, and bitrate-only changes (T-106).
   - Prefs are remembered per device (T-049), so a reconnect normally does not recreate the display.
4. **Is there a user-visible "remove/recover display" action today?** No. The menu (main.swift:52-93) contains: status, video line, tablet settings, tablet files, accessibility hint plus "open System Settings", login item, USB mode, clipboard, logs, "forget approved devices" and Quit. Quit is the only way to remove the display on purpose. There is no "keep display" setting and no remaining-grace indicator. PLAN Aşama 4 lists an unchecked item "Mod seçimi: tablet = ikinci ekran / tablet = ana ekran (monitörsüz) / ekran yansıtma" (PLAN.md:169), but no card exists.
5. **What recovery exists when the tablet is the only screen?**
   - The 10 s auto-teardown is itself the de facto recovery. When the tablet is gone, the virtual display disappears and macOS falls back to the headless placeholder display (1920×1080, `v0x756e6b6e/m0x76697274`, NOTES 2026-09-30 line 160). Parsec (the user's existing tool, NOTES 2026-09-29 line 31; used for approvals, NOTES 2026-09-30 line 253) can then reach it.
   - NOTES 2026-09-29 says an "HDMI dummy stays plugged as a backup". NOTES 2026-09-30 line 160 says the 1920×1080 display is *not* a physical monitor. **Whether the HDMI dummy is actually plugged in is unclear. Ask the user.**
   - There is no crash supervisor and no KeepAlive (grep: only `SMAppService.mainApp`, LoginItem.swift:58). There is no runbook in the repo.
   - Sleep and wake are covered by T-128, T-132, T-133 and T-134 (device-verified, NOTES 2026-10-02 15:47).
6. **Is there a reason the display is torn down, for example a black screen on reuse (T-028)?** T-028 is **not** a reason. That black screen came from a config-ordering bug on the reuse path: the host did not re-send `CODEC_CONFIG` after the tablet's `KEYFRAME_REQUEST(STARTUP)`. T-030 fixed it and it was verified 5/5 on the device (NOTES 2026-09-30 line 204; T-028 card). The real constraints on an H04 fix are:
   - **(a)** A new display cannot be created while the displays sleep (`initWithDescriptor` returns nil, NOTES 2026-10-01 14:10 line 470 / T-040). SCK loses the display during display sleep (-3815). The system then shows the 1920×1080 placeholder. **Nobody has measured whether an existing, retained `CGVirtualDisplay` survives display sleep or system sleep and keeps its window placement.** This is the key unknown for X7.
   - **(b)** The display cannot outlive the host process.
   - **(c)** A refresh change needs a new display, because SCK keeps the creation rate (T-049, NOTES 2026-10-01 line 290).
   - **(d)** Two displays with the same vendor/product/serial cannot coexist (VideoPipeline.swift:132-133).
   - **(e)** The timed teardown is also what hands the Mac back to the placeholder display, and so to Parsec, when the tablet is gone for good. A "keep forever" policy removes that implicit recovery, so it needs an explicit remove action and a bounded default.
   - The 10 s value came from T-014 (NOTES 2026-09-29: "kısa Wi-Fi kopmalarında… bir bekleme süresi gerekli"). No measurement chose it.

## Verdicts

### H04 — Virtual display is tied to connection life
- Verdict: **CONFIRMED** (with corrections).
- Evidence:
  - DisplayLease.swift:9 sets `defaultGraceUs = 10_000_000`. The grace and teardown flow is at DisplayLease.swift:59-67 and StreamCoordinator.swift:290-292 and 392-407.
  - The client's `onStop` sends BYE and closes both connections: `controller.stop()` at MainActivity.kt:1781, inside `onStop` 1758-1784. Backgrounding the app, turning the screen off, locking it, or a network outage longer than 10 s therefore removes the display.
  - The device confirmed this: NOTES 2026-10-02 13:45, "Tablet ekranı kapat/aç (~56 s)… `display_grace_started seconds=10` → `display_teardown`… sanal ekran yeniden oluşturuldu (pencere yerleşimi etkisi kullanıcıya soruldu)".
  - Window impact is device-confirmed: NOTES 2026-09-30 line 206, "Host yeniden başlatılınca Krita'nın pencere düzeni bozuluyor (pencereler 1920×1080 yedek ekrana taşınıp geri geliyor; paneller kayıyor)".
  - Capture and encoder run during grace (`startDrain`, StreamCoordinator.swift:403-405, 719-724).
- Corrections:
  - **Window loss is not total.** Windows come back when the display is recreated with the same vendor/product/serial (VirtualDisplay.swift:40-41, 70), but panels shift. The impact is "layout disturbance", not "windows lost".
  - **The grace waste is smaller than the review implies.** It is bounded to 10 s and is ~0 on a static screen. It was already a known open item in the T-014 handoff.
  - **Missed: a second teardown path.** Any pipeline failure (capture lost, encoder error) invalidates the display immediately (VideoPipeline.swift:290-301, 279-288). During grace nothing rebuilds it (StreamCoordinator.swift:513). In practice this means **the display is almost certainly lost across host sleep, whatever the grace**: T-132 ends the session, the displays sleep, SCK reports -3815, `pipeline_failed`, and the display is invalidated. T-132's handoff assumed the display would be reused after wake inside the grace window (T-132 card, "Sanal ekran — mevcut grace ile bırakıldı (gerekçe)" point 2). That was listed as "cihazda doğrulanacak" and was never confirmed. The NOTES 15:47 log shows `wake_display` right after `session_started`, which fits a fresh create rather than a reuse.
  - **The fix is cheaper than the review implies.** The display handover already exists: `VideoPipeline.stopKeepingDisplay()` (VideoPipeline.swift:248-253) and `init(reusing:)`, added in T-049. A parked display without capture is a small change in host code only.
  - "New session: current keyframe first, then input opens" is already partly true. `prepareForNewConsumer` sends config then keyframe (VideoPipeline.swift:225-234). Input is gated on the session, not on video; that belongs to H02/M01.
- Severity opinion: agree with **High for the stated product goal** (tablet as the sole main screen; user preference in NOTES 2026-09-29 line 31). It is a UX and resource issue, not a safety one, so it rightly comes after H01/H02 (D4 in the review's order). The fix is gated on one measurement, (a) above.

### M06 — Private API and headless recovery as a product boundary
- Verdict: **CONFIRMED**.
- Evidence:
  - `CGVirtualDisplay` is isolated in VirtualDisplay.swift (lines 5, 46-117), using runtime `NSClassFromString`. A missing class throws `VirtualDisplayError.apiUnavailable("… (macOS changed?)")` (lines 19-31). `VirtualDisplayLocator` uses public CG calls only (VirtualDisplayLocator.swift:16-21).
  - The pinch uses an undocumented CGEvent type and fields in one file (MagnifyGestureEvent.swift:4-18). The fallback (IOHIDEvent or key shortcuts) is recorded in decision 0009.
  - On creation failure: `display_create_failed`, and the menu shows "Video başlamadı: …" (StreamCoordinator.swift:598-603). There is no capture fallback. Input to a missing virtual display is dropped by design (VirtualDisplayLocator.swift:21; `input_dropped no_display`, InputController.swift:399-402). **If the private API breaks, the tablet becomes completely useless** (no image, no input).
  - LoginItem is `SMAppService.mainApp` (LoginItem.swift:6, 58). It starts at user login only. There is no crash restart and no KeepAlive (repo grep).
  - SIGINT/TERM/HUP are routed to a clean terminate (main.swift:97-104). A crash or SIGKILL leaves the host down until the next login or a manual open.
  - **First-run flag:** `registerOnFirstRun` writes `loginItemFirstRunDone = true` *before* calling `set(true)` (LoginItem.swift:42-44). On a failed `register()`, `set` only stores the in-memory `problem` and logs `login_item_failed` (lines 60-64). On the next launch the guard returns early (line 42), so there is no retry. `refresh()` only re-shows the approval hint, not the failure (lines 30-36).
- Corrections:
  - The failure is not entirely silent: the first launch's menu shows a line and the log has `login_item_failed`. After that the menu just shows the toggle unchecked, and the user can toggle it by hand.
  - The not-bundled case also sets the flag. An unbundled `swift run` binary very likely uses a different `UserDefaults` domain from `dev.matebridge.host` (not verified), so it probably does not poison the `.app`.
  - "Permission loss not covered" is partly wrong. Accessibility state is re-read whenever the menu opens and is shown with an "open System Settings" item (main.swift:30-31, 206-207, 340-343). Screen Recording loss surfaces only as menu text "Video başlamadı/durdu: … then restart it" (ScreenCapture.swift:15). There is no prompt or deep link.
- Severity opinion: **Medium**, agree. On a headless Mac where the tablet is the only screen, the runbook part matters more than the code. It is mostly documentation plus a rehearsal, and only two small code items (login-item retry, crash restart) are needed.

### SE5 — Sleep covered; reboot, crash, permission and OS update not covered
- Verdict: **CONFIRMED** (minor correction).
- Evidence:
  - BYE(HOST_SLEEP) before the sleep acknowledgement: SessionServer.swift:436-512 (T-132).
  - Display-sleep assertion only while a session is live, and a gated wake: StreamCoordinator.swift:100-108, 319-324, 606-701 (T-128).
  - The client reconnects by direct TCP to the saved IP after wake (T-133/T-134). The whole sleep/wake path was device-verified (NOTES 2026-10-02 15:47).
  - There is no crash supervisor, no reboot/FileVault path and no OS-update check in the code.
- Corrections: Accessibility permission loss *is* surfaced (see M06). Screen Recording loss is surfaced only as text.
- Severity opinion: agree. Reboot with FileVault cannot be fixed in code (preboot happens before any user agent). That is a runbook item: ask the user whether FileVault is on.

### D1 — Safe baseline (build IDs, second access path, fixed test profile)
- Verdict: **CONFIRMED** (the gap is real).
- Evidence:
  - No build identity: `versionName = "0.1"` (client-android/app/build.gradle.kts:16). scripts/bundle-host.sh writes no version or commit into Info.plist (grep: no `version`/`git`). No start-up log line carries a commit.
  - The NOTES "Oturum sonu devir" entries record builds by time ("tablet APK 12:49 (T-125)"), not by SHA.
  - No runbook exists. Parsec as the backup is mentioned only in NOTES 2026-09-29.
- Corrections: none. This overlaps L01 (build identity), so coordinate with whoever has L01.
- Severity opinion: agree. Low cost, high value before any H04 work: H04 changes what happens when the tablet goes away, so the recovery path must be known first.

### D4 — Decouple the virtual display
- Verdict: **PARTIALLY CORRECT**.
- Evidence:
  - The DisplayOwner, keep-main-display preference, media pause/resume and remove/recover menu action are all missing today (see Q4).
  - "Separate bitrate change from display life" is **already done**. A bitrate-only change keeps the display (StreamCoordinator.swift:369-372; T-106; `sameDisplay` VideoSettings.swift:91-93). What remains is separating bitrate from the capture/encoder restart and video reset (H03: in-session `AverageBitRate`), which is not a display issue.
- Corrections: as above. The exit criterion "idle resource use doesn't rise" is right; a parked display without capture should cost ~0.
- Severity opinion: agree with the ordering (after H01/H02).

### X7 — Display continuity: 30 s / 5 min outage, host sleep
- Verdict: **CONFIRMED as a valid acceptance row**. Today it fails by design for 30 s and 5 min (teardown at 10 s). For host sleep it is **NOT VERIFIABLE IN CODE (needs device)**: whether a retained `CGVirtualDisplay` survives display and system sleep is unknown, and today the pipeline-failure path destroys it anyway (see H04).
- Evidence: DisplayLease.swift:9; VideoPipeline.swift:290-301; NOTES 2026-10-01 line 470 (the placeholder display appears during display sleep).
- Corrections: "Window placement preserved during host sleep" may be impossible with this private API if macOS takes virtual displays offline during display sleep. Make that row conditional on the measurement in item P-3.
- Severity opinion: n/a (test row).

### X13 — Soak and recovery (8 h + 1 week; host kill, reboot, permission loss)
- Verdict: **CONFIRMED as missing**. NOT VERIFIABLE IN CODE beyond the following.
- Evidence:
  - Host kill: the SIGTERM path releases input and removes the display (main.swift:97-104, 196-203). On SIGKILL or a crash the OS removes the display and there is no restart.
  - NOTES 2026-09-30 has a 30-min endurance test; there is no 8 h or 1-week record. PLAN Aşama 4's exit criterion "bir hafta… yeniden başlatmam gerekti… kalmıyor" is still unchecked (PLAN.md:171).
- Corrections: none.
- Severity opinion: agree. Do it after H04/H01/H02 have landed, otherwise the soak measures known issues.

### A1 — DisplayOwner (lifetime = Mac user session / explicit user preference)
- Verdict: **PARTIALLY CORRECT**.
- Evidence:
  - The code already has a pure policy (`DisplayLease`), a single owner (`StreamCoordinator`'s serialized mailbox, StreamCoordinator.swift:8-12, 79) and a display handover (`stopKeepingDisplay` / `reusing:`).
  - What couples display and media is that `VideoPipeline` *owns* the `VirtualDisplay` (VideoPipeline.swift:42, 53, 271-288) and destroys it on any media failure.
- Corrections:
  - "Lifetime = Mac user session" is not achievable: a `CGVirtualDisplay` lives at most as long as the host process (VirtualDisplay.swift:12-13). The honest lifetime is "host process, bounded by a user preference".
  - No new type hierarchy is needed. Moving the `VirtualDisplay` reference from `VideoPipeline` into the coordinator (a "parked display" slot) plus a `DisplayLease` state such as `parked(deadline)` is enough.
- Severity opinion: agree that it is the right shape, and it is small. Keep it inside StreamCoordinator, DisplayLease and VideoPipeline.

### A6 — Dynamic quality: display refresh change recreates the display
- Verdict: **PARTIALLY CORRECT**.
- Evidence: a refresh change recreates the display (VideoPipeline.swift:129-143). A bitrate or scale change keeps it, but every `STREAM_PREFS` change restarts capture and encoder and resets the video connection with a new `config_id` (StreamCoordinator.swift:373-390; `onReconfigure` → SessionMachine.reconfigure). Stable 60/120 profiles already exist (5 modes, remembered per device, T-049/T-143).
- Corrections: "Bitrate as the first fast lever" is not available today without a media restart. That is H03's in-session bitrate item, not a display issue.
- Severity opinion: agree with the guidance.

### PF5 (the "mode switch can recreate display" part)
- Verdict: **ALREADY ADDRESSED** (decision 0016), and slightly overstated.
- Evidence: decision 0016 §Bağlam: "Modun kendiliğinden değişmesi istenmiyor, çünkü her mod değişimi sanal ekranı yeniden kuruyor ve kısa bir kararma oluyor". No automatic switching exists. Only 60↔120 refresh changes recreate the display (see Q3). The first connection of a device with no stored prefs and a 120 Hz mode recreates it once (T-049 handoff, round 2).
- Corrections: decision 0016's wording "her mod değişimi" is inaccurate (Akıcı↔Performans↔Oyun 120 keep the display). A doc nit only.
- Severity opinion: agree that stable profiles are preferred.

### F2 (the "display lifetime from session" part)
- Verdict: **CONFIRMED**. Same evidence as H04.
- Corrections: a narrow change, not a rewrite (see A1). It includes the pipeline-failure teardown path.
- Severity opinion: agree.

### F5 (the "second access path ready" part)
- Verdict: **CONFIRMED** (the gap is real).
- Evidence: the only record is NOTES 2026-09-29 line 31 (HDMI dummy plus Parsec as backup). NOTES 2026-09-30 line 160 says the 1920×1080 display is the headless placeholder, not a monitor, so whether the HDMI dummy is in place is unclear. There is no runbook, no rehearsal record, and macOS Screen Sharing/SSH status is undocumented. NOTES 2026-10-01 line 473 lists local-only Screen Sharing as an unverified option.
- Corrections: none.
- Severity opinion: agree. This is a precondition for H04: a longer-lived parked display makes a working second path *more* important.

### W4 — "Mac session" row of the thread map
- Verdict: **CONFIRMED**.
- Evidence:
  - One serial session queue (SessionServer.swift:210). Handlers are called synchronously on it (SessionServer.swift:1472-1474, 1538-1550).
  - Input hops synchronously to its own serial queue (InputController.swift:9-13, 77, 182), so a slow CGEvent call can delay the session queue, as the review says.
  - Video and display work is decoupled: `coordinator.sessionStarted/Ended` only post to a bounded mailbox (capacity 16, StreamCoordinator.swift:79, 135-151). Display creation therefore never blocks the session queue. That creation can take ~2 s in `selectMode` + 0.7 s + up to 5 s of SCK retries.
- Corrections: none for this row.
- Severity opinion: agree (informational).

## Additional issues found

1. **A pipeline failure destroys the virtual display.** VideoPipeline.swift:22-24, 290-301 → `teardown()` 279-288 `disp?.invalidate()`. A transient capture error (for example SCK -3817 when the user stops capture from the menu-bar indicator, NOTES 2026-09-30 line 196) removes the display and makes windows migrate, even though the display itself was fine. During grace there is no rebuild (StreamCoordinator.swift:513). This should be part of the H04 fix (see P-5), subject to the display-sleep measurement.
2. **T-132's display-reuse-after-wake assumption is unverified and probably false**, by the path in item 1 (T-132 card, Handoff rationale point 2 and the untested item "sanal ekranın grace içinde yeniden kullanıldığı"). Check host.log from a sleep test for `display_reused` vs `display_created` after `session_started`.
3. **Blocking sleep inside async context.** `VirtualDisplay.selectMode` calls `Thread.sleep(0.1)` up to 20 times (VirtualDisplay.swift:134-146) from `VideoPipeline.obtainDisplay`, which runs on a Swift-concurrency cooperative thread (VideoPipeline.swift:101, 141). That holds a cooperative thread for up to 2 s. Low severity; note it, don't fix it in isolation.
4. **The recreate path has no fallback.** `obtainDisplay` invalidates the old display, sleeps a fixed 700 ms, then creates the new one (VideoPipeline.swift:136-142). If creation fails (for example the displays are asleep), there is no display at all until the next video reconnect. Low.
5. **Grace and keep durations count awake time only** (HostClock = mach absolute time, HostClock.swift:8-10). That is fine for 10 s. If a future "keep 30 min" preference is meant as wall time, it needs a continuous clock (`mach_continuous_time`). Design note for P-2.
6. **No display-sleep assertion while parked.** The assertion is released at session end (StreamCoordinator.swift:396), so a parked display will meet macOS idle display sleep after the user's timeout. Whether that takes the virtual display offline (and migrates windows) is part of measurement P-3.
7. **Doc nit:** decision 0016 says "her mod değişimi sanal ekranı yeniden kuruyor"; only refresh changes do.

## Proposed work items

Card text should be in Turkish per the conventions. Drafts are in English here. The next decision number is **0018** (0017 exists, withdrawn).

### P-1 — Record the virtual-display lifetime policy (decision 0018)
- owner: orchestrator (with a user choice). depends_on: P-3 (finalize after the measurement; it can be drafted as "önerildi" now). Decision record: yes (this is it). Protocol change: none.
- files: `docs/decisions/0018-virtual-display-lifetime.md`, `docs/decisions/README.md`, `docs/PLAN.md` (Aşama 4 "Mod seçimi" item).
- Draft decision: The virtual display's life is separated from the control session. When a session ends, the host releases input (unchanged), stops capture, encoder and audio, and **parks** the display. The display object stays alive with its identity, size and refresh rate, so window placement is kept. Media is rebuilt on the parked display when the same device returns with a compatible size. The parked display is removed when one of these happens:
  - a user-chosen keep time expires (options: 10 s / 5 min / 30 min / until Quit; default chosen by the user after P-3);
  - the user picks "Sanal ekranı şimdi kaldır";
  - a different device or display size connects;
  - a refresh change requires recreation;
  - the host quits.
  
  Rationale: the tablet is the sole main screen (NOTES 2026-09-29), and screen-off for more than 10 s currently disturbs layout (NOTES 2026-10-02 13:45). A bounded default plus an explicit remove action preserve the implicit recovery that today's 10 s teardown provides (windows fall back to the headless placeholder, which Parsec can reach). Revisit if P-3 shows that macOS takes virtual displays offline during display or system sleep anyway.
- Acceptance: [ ] decision accepted by the user, with the default keep time; [ ] PLAN item updated.

### P-2 — Host: park the virtual display after a session ends (no capture or encode while parked)
- owner: mac-host-dev. depends_on: none for the mechanism (the default stays 10 s, so behaviour is unchanged except that media stops during grace). Decision record: not for this card (the knob is an experiment knob; the default policy comes from P-1). Protocol change: **none**.
- files:
  - `host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift`
  - `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`
  - `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`
  - `host-mac/Tests/MateBridgeCoreTests/Video/IntegrationTests.swift` (the `DisplayLeaseTests`) or a new `host-mac/Tests/MateBridgeCoreTests/Video/DisplayLeaseTests.swift`
  - `docs/LOGGING.md` (new events)
  - the card.
- Goal: when a session ends, stop SCK and VT immediately and keep only the `VirtualDisplay` alive for the keep window. When the same device returns with the same display size, build a fresh pipeline on the parked display. This removes idle cost during grace and turns the keep time into a cheap, configurable number.
- Out of scope: the menu UI (P-4); changing the default from 10 s; a pipeline-failure display handback (P-5); any client change.
- Acceptance criteria:
  - [ ] XCTest `DisplayLease`: `sessionEnded` yields a park action (for example `.park`) instead of only a state change; `tick` past the deadline yields `.teardown` exactly once; a same device + `sameDisplay` session yields `.create(settings)` *reusing the parked display* (new action or flag); refresh mismatch yields recreate; a different device or size yields teardown + create; `shutdown` while parked yields teardown; `displayLost` while parked yields idle. Keep the existing test semantics for the 10 s default.
  - [ ] XCTest: the keep duration comes from the env knob `MATEBRIDGE_DISPLAY_KEEP_S` (parse 10…86400, otherwise default 10). This is a pure parse function in Core.
  - [ ] Log: `display_parked keep_s=N`, `display_unparked`, `display_teardown reason=keep_expired|device_changed|size_changed|shutdown`.
  - [ ] Mac (device): after the tablet screen goes off, MateBridgeApp CPU and GPU drop to idle while parked (Activity Monitor). Reconnect within the keep window shows the image within 1 s **on a static screen as well, 5/5** (T-028 regression guard). Reconnect after a Smooth→Clarity change while parked recreates once.
  - [ ] `./scripts/check.sh` passes.
- Plan hints:
  - Make `onSessionEnded` call `pipeline.stopKeepingDisplay()` instead of `startDrain()`. Store the result in a coordinator field `parked: VirtualDisplay?`. Then `createPipeline(settings:, reusing: parked)`.
  - `restartPipeline` (StreamCoordinator.swift:564-574) already does this hand-off and was device-tested in T-049, so the risk is low.
  - On a static screen the new pipeline needs SCK's first frame before `prepareForNewConsumer` can force a keyframe. That is the same as the reconfigure path (works on device), but verify it explicitly.
  - `onPipelineFailed` with `parked` present: none (no pipeline). `onShutdown` must invalidate `parked`.
  - Keep `perform(lease…)` the single place that creates or removes displays.
  - Risk: a parked display whose underlying CG display went offline (display sleep). `obtainDisplay` should fall back to creating a new one if `CGDisplayIsOnline(parked.displayID)` is false. Use public CG only; `VirtualDisplay` stays the only private-API file.

### P-3 — Measure parked-display behaviour across sleep, lock and long outages (gates P-1's default and P-5)
- owner: user (procedure run by the orchestrator). depends_on: P-2 (needs the `MATEBRIDGE_DISPLAY_KEEP_S` knob). Decision record: no (it feeds 0018). Protocol: none.
- files: `docs/NOTES.md` (dated entry), the card.
- Goal: find out whether a retained `CGVirtualDisplay` without capture keeps its identity and window placement through display sleep, system sleep, lock and long outages, and whether the second access path still works while it is parked.
- Procedure (host started with `MATEBRIDGE_DISPLAY_KEEP_S=3600`, Krita plus 2 windows arranged):
  1. Tablet screen off for 30 s, then 5 min, then back on. Expect `display_unparked`. Record whether the window and panel positions are unchanged, and the time to first image.
  2. While parked: `pmset displaysleepnow`, wait 60 s, wake. Check `CGDisplayIsOnline` (or `system_profiler SPDisplaysDataType`) for the `v0x4d42/m0x1` display during and after sleep, and window placement after the tablet reconnects.
  3. While parked: `pmset sleepnow` (expect T-132 BYE), wake via the tablet (T-134), then the same checks. Grep host.log for `display_reused/display_created/display_create_failed`.
  4. While parked and the tablet is away: connect with Parsec. Can it see and control the parked display (the Mac's only display)?
  5. Idle cost while parked for 5 min: MateBridgeApp CPU, GPU and RSS.
- Acceptance: [ ] NOTES entry with the five results; [ ] the user picks the P-1 default; [ ] it is clear whether P-5 is feasible (does the display survive display sleep?).

### P-4 — Host menu: virtual-display keep preference and "remove display now"
- owner: mac-host-dev. depends_on: P-2, P-1 (accepted). Decision record: 0018 (from P-1). Protocol: none.
- files:
  - `host-mac/Sources/MateBridgeApp/main.swift`
  - `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`
  - `host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift` (keep-duration setter)
  - a new Core preference file, e.g. `host-mac/Sources/MateBridgeCore/Video/DisplayKeepPolicy.swift`, plus its test
  - the card.
- Goal: let the user choose how long the display stays after the tablet leaves (the options from 0018, persisted in UserDefaults; env knob P-2 still wins), and give an explicit "Sanal ekranı şimdi kaldır" action. The status line should show "Sanal ekran bekletiliyor (mm:ss)" while parked. The remove action is the recovery path when the tablet is gone and the user, via Parsec, wants the windows back on the placeholder display.
- Out of scope: a "recreate display without a tablet" action. That needs its own decision: it is only useful with Parsec viewing, and it risks hiding windows on an unwatched display.
- Acceptance:
  - [ ] XCTest: preference parse, default and persistence round-trip; a lease keep-duration change while parked takes effect from now (not retroactively shorter than 0).
  - [ ] "Remove now" while a session is live is disabled or hidden (removing a watched display is not the goal), or it ends the session first. Choose one and justify it in Plan.
  - [ ] Mac (device): menu → remove while parked brings windows back to the placeholder display, and the log shows `display_teardown reason=user`.
  - [ ] `./scripts/check.sh` passes.
- Plan hints: route the menu action through `StreamCoordinator` as a new mailbox event (lifecycle, forced like `sessionEnded`) so it is ordered with session events. Do not touch `VirtualDisplay` directly from the app.

### P-5 — Host: do not destroy a healthy display on capture/encoder failure (conditional on P-3)
- owner: mac-host-dev. depends_on: P-2, P-3 (only if P-3 shows the display survives display sleep, or the failure was not display-related). Decision record: no. Protocol: none.
- files: `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`, `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`, a Core policy file plus test if there is logic (e.g. `DisplayWakePolicy.swift` or a new `PipelineFailurePolicy.swift`), the card.
- Goal: when SCK or VT fails but the virtual display is still online, hand the display back (like `stopKeepingDisplay`) instead of invalidating it, so windows do not migrate. The rebuild then reuses it. Today every failure invalidates the display (VideoPipeline.swift:290-301).
- Acceptance:
  - [ ] XCTest of the pure decision: error kind × `displayOnline` → keep or invalidate.
  - [ ] Mac (device): stopping capture from the menu-bar recording indicator (SCK -3817, NOTES 2026-09-30) recovers without window movement.
  - [ ] Display sleep behaviour matches the P-3 result.
- Plan hints: `onFailure` must carry the kept display back to the coordinator through the mailbox (`pipelineFailed(…, display:)`). Ownership must stay single: either the pipeline or the coordinator holds it, never both.

### P-6 — Host: login-item registration failure must not block retry
- owner: mac-host-dev. depends_on: none. Decision record: no. Protocol: none.
- files: `host-mac/Sources/MateBridgeApp/LoginItem.swift`, a new `host-mac/Sources/MateBridgeCore/Session/LoginItemPolicy.swift` (pure), `host-mac/Tests/MateBridgeCoreTests/Session/LoginItemPolicyTests.swift`, the card.
- Goal: today `loginItemFirstRunDone` is set before `register()` is attempted (LoginItem.swift:42-44), so one failed registration means the app never starts at login and never retries. Mark first-run done only after a successful registration, or after the user toggles explicitly, and show the stored failure in the menu on later launches.
- Out of scope: a KeepAlive or crash supervisor (P-8).
- Acceptance:
  - [ ] XCTest (pure policy): first run + success → done; first run + failure → not done, retried next launch, problem shown; user toggled off → done, never auto-registered again; not bundled → nothing persisted.
  - [ ] Mac (device): a bundled app with the login item removed in System Settings and the flag reset (`defaults delete dev.matebridge.host loginItemFirstRunDone`) registers on the next launch.
  - [ ] `./scripts/check.sh` passes.

### P-7 — Recovery runbook, supported-version record and OS-update smoke checklist (D1, M06, F5, X13)
- owner: orchestrator (writes it), user (rehearses it). depends_on: none. Decision record: no (documentation). Protocol: none.
- files: a new `docs/RECOVERY.md` (Turkish), `README.md` (link plus current state), `docs/NOTES.md` (rehearsal results), the card.
- Goal: a one-page, tested answer to "the tablet shows nothing — how do I reach the Mac?" covering:
  - host quit or crash (how to relaunch without a screen: Parsec, SSH `open -a`, or macOS Screen Sharing, whichever the user has; ask);
  - tablet app crash;
  - network loss (USB fallback);
  - Screen Recording or Accessibility revoked (where to re-grant; Screen Recording needs an app restart, ScreenCapture.swift:15);
  - reboot with or without FileVault (ask the user; preboot needs a physical keyboard and screen or an HDMI dummy plus remote access);
  - login and logout;
  - after a macOS update: a 5-minute smoke test (display created at 2800×1840 @60 and @120, `mode_selected=true`, Krita pen pressure, tilt and hover, pinch zoom in Krita, Ctrl↔Cmd shortcuts, sleep/wake once).
  
  Also record the last known-good pair: macOS build, HarmonyOS build, host commit, APK commit.
- Acceptance: [ ] each scenario rehearsed once by the user and recorded in NOTES with its date; [ ] HDMI dummy presence confirmed or the plan updated; [ ] README states the supported versions.

### P-8 — (Optional, decision needed) Host restarts itself after a crash
- owner: mac-host-dev. depends_on: P-7 (the rehearsal shows whether it is needed). Decision record: **yes**. Draft: "Host crash recovery via a LaunchAgent with `KeepAlive {SuccessfulExit: false}` registered by `SMAppService.agent(plistName:)` instead of `mainApp`. Clean Quit stays quit; a crash relaunches within seconds; TCC grants stay keyed to the same bundle ID. Trade-off: a crash loop must be bounded (`ThrottleInterval`), and the menu login toggle must manage the agent." Protocol: none.
- files: `host-mac/Sources/MateBridgeApp/LoginItem.swift`, `scripts/bundle-host.sh` (embed `Contents/Library/LaunchAgents/*.plist`), the card.
- Acceptance: [ ] `kill -SEGV` on the host brings it back within ~10 s and the tablet reconnects; [ ] Quit from the menu does not relaunch; [ ] TCC permissions persist.

### P-9 — (Optional, research) Fallback when `CGVirtualDisplay` is unavailable
- owner: orchestrator (research). depends_on: P-7. Decision record: yes, if adopted. Protocol: possibly none (`STREAM_CONFIG` already carries size). Input mapping would target the main display via the `DisplayProviding` seam (VirtualDisplayLocator.swift:6-10).
- Goal: decide whether, on `VirtualDisplayError.apiUnavailable/creationFailed`, the host should stream the main (placeholder or physical) display with input mapped to it, so a macOS update that breaks the private API leaves the Mac reachable from the tablet at reduced quality. On a headless Mac that display is the 1920×1080 placeholder (wrong aspect, low resolution), so the value is "reachability", not quality.
- Acceptance: [ ] a short research note (does SCK capture the headless placeholder; does input mapping work) and a go/no-go recorded in a decision.

## Coverage

| ID | Verdict |
|---|---|
| H04 (all sub-points) | CONFIRMED (with corrections) |
| M06 (all) | CONFIRMED |
| SE5 | CONFIRMED (minor correction) |
| D1 | CONFIRMED (gap is real) |
| D4 | PARTIALLY CORRECT |
| X7 | CONFIRMED as a row; host-sleep part NOT VERIFIABLE IN CODE |
| X13 | CONFIRMED as missing |
| A1 (DisplayOwner) | PARTIALLY CORRECT |
| A6 | PARTIALLY CORRECT |
| PF5 (mode-switch part) | ALREADY ADDRESSED (decision 0016), slightly overstated |
| F2 (display-lifetime part) | CONFIRMED |
| F5 (second-access-path part) | CONFIRMED |
| W4 ("Mac session" row) | CONFIRMED |

All 13 assigned IDs have a verdict entry.
