# Verification G — input chain, pen model, palm rejection, keyboard/mouse

Verifier scope: M04, IN1–IN10, PK1–PK8, X2, X9, X10, D7, A5, L03 (input side), W4 rows "Android UI" + "Mac input", F1 (input/stylus strengths).
Code at HEAD a30c769. Paths abbreviated: `client/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`, `Core/` = `host-mac/Sources/MateBridgeCore/`, `Host/` = `host-mac/Sources/MateBridgeHost/`.

## Verdicts

### M04 — Pen time intervals and input freshness not carried end to end
- Verdict: CONFIRMED in every code detail. It is also a **known, deliberately deferred** item that the review did not cite.
- Evidence (M04 sub-questions):
  1. **Are per-sample time deltas on the wire? Yes.** PEN carries `base_time_us` (u64) plus `dt_us` (u32) per sample: PROTOCOL.md §4 PEN (lines 242–262), `Core/Messages.swift:466-539` (decoder rejects decreasing `dt`). The client fills them from `MotionEvent.getHistoricalEventTime(h)*1000` / `eventTime*1000` (`client/input/MotionEventAdapter.kt:169,179`). `PenTracker.emit` builds `base = chunk[0].timeUs` and `dt = timeUs - base` (`client/input/PenTracker.kt:350-358`). Resolution is **1 ms**, because on API 31 event times are milliseconds (PROTOCOL §1). Times are clamped monotonic (`PenTracker.kt:284`). Liveness repeats and synthetic closes use dispatch time `nowMs*1000` (`PenTracker.kt:188,195,406`).
  2. **Does the host ignore them? Yes.** `InputStateMachine.handlePen` loops `for sample in batch.samples` and never reads `baseTimeUs`/`dtUs` (`Core/Input/InputStateMachine+Pen.swift:16-24`). A grep for `baseTimeUs|dtUs|timeUs` in `Core/Input/` and `Host/Session/` finds no consumer. `InputController.deliver` → `flush` → `CGEventPoster.post` posts the whole batch back to back in one loop (`Host/Input/InputController.swift:177-200,296-306`, `Host/Input/CGEventPoster.swift:33-63`). KEY/POINTER/SCROLL/PINCH `time_us` are ignored too. PROTOCOL §7 says so explicitly: "mesajdaki `*_time_us` kullanılmaz" (watchdogs use receipt time).
  3. **CGEvent timestamp: never set.** `CGEventFactory` sets no `.timestamp` (`CGEventPoster.swift:79-220`), so each event carries its creation time on the host, i.e. the post time. NOTES 2026-09-30 (line 198) records the same: "Host, CGEvent zaman damgasını ayarlamıyor (gönderim anı)".
  4. **Input sequence number / capture-to-injection age: none anywhere.** Input messages have no seq (only PING `seq` and CLIPBOARD `seq` exist). The host never sends PING and ignores PONG (`Core/Session/SessionMachine.swift:741-756`), so it has no clock offset and cannot compute age. Only the client estimates the offset. Client: the `SendQueue` age bound (1 s) is checked only at `offer` time (`client/session/SendQueue.kt:25-36`). The control socket is a plain Java `Socket` with only `tcpNoDelay` set (`client/session/SessionController.kt:641`): no SNDBUF cap and no NOTSENT_LOWAT, so bytes already in the kernel are not age-bounded.
- Corrections / missed context:
  - **Already tracked:** PLAN.md Aşama 5 (line 181) has "Wi-Fi'de kalem örneklerini zamana yayma (host)", a user decision of 2026-09-30 ("acelesi yok, en sona"). It uses the same 8–12 ms Wi-Fi estimate and the same "pen-up / release-all flush immediately" rule. NOTES 2026-09-30 (lines 169–178) has the arrival-interval table: USB median 2.8 ms, Wi-Fi median 0.5–1.1 ms with p95 ~10 ms. The user chose USB for drawing.
  - **The client-side cause of bursts was already removed.** T-026 (`client/input/UnbufferedPenDispatch.kt`, verified on device as `path=source`, `max_batch` 1–2) sends one sample per PEN message. Bursts now come from the network, not from batching.
  - **The line-quality benefit is unproven.** In the Krita spike study (NOTES lines 210–222), no event-timing change helped: rate, minimum 2.5 ms spacing, or Krita's "use tablet driver timestamps". Only Krita smoothing = None removed the spikes. Wi-Fi "köşeli" is a qualitative user report.
  - **The Wi-Fi numbers predate T-111.** T-111 moved the control connection to a kernel BSD socket and is done, but the T-111 handoff check "Wi-Fi'de kalem öbeklenmesi" was never recorded in NOTES.
  - **PROTOCOL §4 overstates the freshness bound.** Its "Kabul edilen davranış" gives the client queue (1 s) as the upper bound on late strokes, but kernel-buffered input is not covered. The effective bound is the host's 5 s silence close (§6). Between 1.5 and 5 s a release-all and latch happen, yet complete later clicks, keys and strokes (with `STROKE_START`) still replay late. The review is right on this point.
- Severity opinion: Medium is right for Wi-Fi drawing and freshness. It is Low for the user's chosen USB path. The freshness half (late clicks/keys after a stall, see also the key-repeat issue below) matters more for safety than the rhythm half.

### IN1 — Input flow description
- Verdict: CONFIRMED
- Evidence: Adapter/trackers run on the UI thread (`client/input/MotionEventAdapter.kt:26-91`, `InputCapture.kt:10-12`). `InputOutbox` merges only plain hover PEN, SCROLL/PINCH CHANGED and same-button POINTER_REL (`InputOutbox.kt:104-124`). The sink calls `controller.trySendInput` → `ControlLink.send` → bounded `SendQueue` directly from the UI thread (`MainActivity.kt:553-556`, `SessionController.kt:288-293`). Host: `SessionServer.apply` `.deliver` → `main.swift:156-160` handler → `InputController.deliver` (`queue.sync`) → `InputPipeline` (owed releases, `Core/Input/OwedRelease.swift`) → `CGEventPoster` posts at `.cghidEventTap` (`CGEventPoster.swift:60`).
- Corrections: none.
- Severity opinion: descriptive, n/a.

### IN2 — Coordinates
- Verdict: CONFIRMED
- Evidence: Client `Coords.normalize` maps to u16 against the video surface (`client/protocol/Coords.kt:22-26`). Host `DisplayGeometry.point` converts with `origin + v/65535*extentPt`, clamped to `extent − 1/scale` (`Core/Input/Geometry+Display.swift:51-92`). 1400 pt × scale 2 / 65535 ≈ 0.043 px per step.
- Corrections: none.
- Severity opinion: agree, not a problem.

### IN3 — Pressure
- Verdict: CONFIRMED
- Evidence: `Coords.pressure` maps 0..1 to u16 (`Coords.kt:29-32`), and pressure is 0 unless CONTACT (`PenTracker.kt:289`). Host `pressureUnit` (`Core/Input/InjectAction.swift:57`) sets `mouseEventPressure` and `tabletEventPointPressure` (`CGEventPoster.swift:161-163`). Down/drag/up come from contact, never from pressure (`CGEventPoster.swift:153`, `InputStateMachine+Pen.swift:29-32`). NOTES line 45 records 16384 levels (14 bit), max seen 0.879. There is no pressure curve anywhere (linear).
- Corrections: none.
- Severity opinion: agree.

### IN4 — Tilt conversion and calibration
- Verdict: CONFIRMED
- Evidence: `Coords.penTilt` computes x = sin t·sin o and y = −sin t·cos o, marked "provisional, to be calibrated" (`Coords.kt:246-256`; PROTOCOL §4 says "geçicidir ve cihazda kalibre edilecektir"). Unreported tilt during contact repeats the last value (`PenTracker.kt:298-310`). On device, only a qualitative check was done: Krita "Pencil-5 Tilted" changes with tilt, xTilt/yTilt ≈ 12–29 (T-025, NOTES line 233). Sign and axis were never checked in 4 directions.
- Corrections: none. The app also allows both landscape rotations (`AndroidManifest.xml:22,33` `sensorLandscape`), so the AXIS_ORIENTATION frame must be checked after a 180° flip as well.
- Severity opinion: Low (a quality issue, not safety).

### IN5 — Hover
- Verdict: CONFIRMED
- Evidence: HOVER_ENTER/MOVE/EXIT map to IN_RANGE (`MotionEventAdapter.kt:42-50`, `PenTracker.kt:150-162`). The host turns these into proximity enter/leave plus hover (`InputStateMachine+Pen.swift:54-79`). AXIS_DISTANCE is never read; NOTES line 47 says it is always 0.
- Corrections: none.
- Severity opinion: n/a.

### IN6 — Drag and STROKE_START latch
- Verdict: CONFIRMED
- Evidence: Host latch rule at `InputStateMachine+Pen.swift:41-49`, set at session start and every release-all (`InputStateMachine.swift:273`). Client: a MOVE without a DOWN goes out as hover (`PenTracker.kt:134-139`, `reset()` at 221-229).
- Corrections: none.
- Severity opinion: n/a (strength).

### IN7 — Pointer ownership
- Verdict: CONFIRMED
- Evidence: `leftOwner` gives the pen priority (`InputStateMachine+Pen.swift:104-111`) and the OWN/GATE rules live in `InputStateMachine+Pointer.swift:20-58`. Hover is suppressed while another source owns the left button (`+Pen.swift:77-79`).
- Corrections: none.
- Severity opinion: n/a.

### IN8 — History samples carried, host does not apply original intervals
- Verdict: CONFIRMED (duplicate of M04 point 2)
- Evidence: `MotionEventAdapter.penFrame` keeps all history (`:162-190`). The host ignores `dt` (see M04).
- Corrections: the review omits that T-026 made batches 1–2 samples on the device, and that PLAN Aşama 5 tracks the host-side fix.
- Severity opinion: as M04.

### IN9 — Unbuffered dispatch
- Verdict: CONFIRMED
- Evidence: API ≥ 30 uses `requestUnbufferedDispatch(SOURCE_STYLUS)` on the leaf `video` view (`UnbufferedPenDispatch.kt:276,296-322`, `MainActivity.kt:566-575`). Older APIs use a per-gesture request on pen ACTION_DOWN (`MainActivity.kt:694-695`). On device (API 31), `path=source` was logged (NOTES line 169).
- Corrections: none.
- Severity opinion: n/a.

### IN10 — 10 ms / 40 ms / 25 ms numbers
- Verdict: CONFIRMED, with small corrections.
- Evidence:
  - `CONFIRM_MS = 10` (`PenTracker.kt:426`). A second real sample confirms immediately (`:240-256`). The code comment assumes ~2.8 ms at 360 Hz; NOTES has ~330 Hz (line 44) and 360 Hz (line 169).
  - `EXIT_DEFER_MS = 40` (`:419`).
  - The tick is `INPUT_TICK_MS = 25` (`MainActivity.kt:944-953,2078`), giving a worst-case timer confirmation ≈ 35 ms (PROTOCOL §7 says "≈35 ms").
- Corrections:
  - The 25 ms is the UI **input ticker**, not a "control interval".
  - Because the exit is settled by the tick, its effective deferral can reach ~65 ms; PROTOCOL §4 documents "en çok ~65 ms".
  - Confirmation adds ≈ 3 ms (one sample) to stroke start, not 10 ms (decision 0007).
- Severity opinion: agree it is negligible.

### PK1 — Mac posts tablet identity, proximity and tablet-point events
- Verdict: CONFIRMED
- Evidence: Proximity events with vendor/tablet/pointer IDs, Wacom `vendorPointerType`, `uniqueID` and capability mask (`CGEventPoster.swift:129-143`, T-031). Mouse events carry subtype `tabletPoint`, pressure, tiltX/Y and rotation 0 (`:145-168`). Krita 5.3.4 pressure drawing works (NOTES 2026-09-30, T-025).
- Corrections: none.
- Severity opinion: n/a.

### PK2 — Tilt sparse in contact; validation matrix needed
- Verdict: CONFIRMED (the fact). The validation matrix has not been run.
- Evidence: NOTES line 46: 1–5 distinct tilt values per stroke in contact, 417+ while hovering. The client repeats the last value (`PenTracker.kt:294-310`). T-025 checked tilt only qualitatively. No test exists for 4 directions × 2 landscape rotations × corners + centre.
- Corrections: none. The sparse updates are a platform property seen in the raw probe (T-003), not an app bug, which NOTES already separates.
- Severity opinion: Low.

### PK3 — Edge-case pen tests; short-contact filter; pressure curve
- Verdict: NOT VERIFIABLE IN CODE (needs device). The code facts are confirmed.
- Evidence:
  - Pressure is linear end to end (no curve in `Coords.kt`, `InjectAction.swift`, `CGEventPoster.swift`), so there is no double curve.
  - The short-contact filter drops only a contact that ends while held: a single sample, no history, under 10 ms by event time (`PenTracker.kt:240-256`, decision 0007).
  - Device check so far: only synthetic `adb input stylus tap` dots (dropped, as intended) and drawing in Krita (NOTES line 205). No real light-tap or dot-size test with the M-Pencil.
  - Covered on device: cable pull, Home, notification panel and force-stop mid-stroke (T-025). Not covered: Wi-Fi off mid-stroke.
- Corrections: none.
- Severity opinion: Low–Medium (a dropped real dot would be a correctness bug for drawing).

### PK4 — Palm rejection limits on API 31
- Verdict: CONFIRMED
- Evidence:
  - `targetSdk = 31` (`client-android/app/build.gradle.kts:14`), and the device is API 31 (NOTES line 14).
  - FLAG_CANCELED (API 33) and TOOL_TYPE_PALM are never used (grep).
  - The adapter routes releases by (device, pointer) and treats non-FINGER/STYLUS tools as never-pressing (`MotionEventAdapter.kt:51-87`, `ReleaseRouting`).
  - NOTES line 50: on this device the palm arrives as **FINGER** from `input_mt_wrapper`, so tool type alone cannot reject it.
- Corrections: none.
- Severity opinion: agree.

### PK5 — Palm click already sent; optional "finger off / navigate only" policy
- Verdict: ALREADY ADDRESSED by decision 0006 §2, implemented and validated on device. A narrow residual remains.
- Evidence:
  - Client gate: new finger presses, scrolls and pinches are refused while the pen is in range and for 1.2 s after the last PEN message (`client/input/TouchTracker.kt:412-413,445`). A pending or pressed finger is released when the pen enters range (`:186-193`). A "Parmak dokunmasını tamamen kapat" setting exists (`:37,196-199`; `InputCapture.setFingersDisabled`).
  - Host gate: 1 s, measured from receipt (`Core/Input/InputStateMachine.swift:40,140-144`; `+Pointer.swift:20-58`; `+Pinch.swift:17`).
  - T-025: palm rejection "çalışıyor" (user).
- Corrections:
  - The review presents this policy as a future option, but it is the default today.
  - Residual risk the review correctly hints at: a palm that lands **before** the pen comes into range and is held > `HOLD_MS` = 40 ms, or moves > 16 px (`TouchTracker.kt:140,429-430`), is sent as a click or drag. The later pen-range release cannot undo it.
  - Pinch and scroll are also blocked while the pen hovers. The review's "pinch-protecting narrow policy" would be a UX change; the user has not asked for it.
- Severity opinion: Low (no user complaint; residual edge case).

### PK6 — Mouse/keyboard design
- Verdict: CONFIRMED
- Evidence:
  - Relative pointer sums history deltas (`MotionEventAdapter.kt:121-139`).
  - The client drops `repeatCount > 0` (PROTOCOL §4 KEY). The host ignores duplicate DOWNs (KEY-DUP, `Core/Input/InputStateMachine+Keyboard.swift:73,87`).
  - UP releases what DOWN recorded (`:86-92`).
  - Release-all sends ordinary keys before modifiers (`:108-119`), and pointer/pen ups come before keys (`InputStateMachine.swift:247-275`).
- Corrections: none.
- Severity opinion: n/a (strength).

### PK7 — Real-app keyboard tests; IME is separate
- Verdict: ALREADY ADDRESSED (mostly; NOTES 2026-09-30 "Faz 3 ilk cihaz testi", line 245)
- Evidence:
  - Validated by the user: Turkish characters, `"` and `<` (ISO keys), AltGr+Q, Ctrl→Cmd shortcuts, repeat, Caps Lock, no stuck key on background.
  - The lock-screen password typed from the tablet works (NOTES line 475).
  - IME/compose is out of scope by design: decision 0003 sends physical keys and the Mac input source produces characters.
- Corrections:
  - Still untested on device: dead keys, Glide keyboard detach mid-hold (`InputCapture.onDeviceRemoved`, T-033 handoff), and secure-input fields other than loginwindow.
  - A real **Control** key is unavailable by default (decision 0008: Ctrl→Cmd, Meta→Control, and the Glide keyboard has no Meta). The review did not mention this known gap.
- Severity opinion: Low.

### PK8 — Cursor embedded in capture; local cursor layer
- Verdict: CONFIRMED (`showsCursor = true`, `Host/Video/ScreenCapture.swift:62`). Partly already addressed for the pen.
- Evidence: There is no local mouse-cursor layer on the client. A local **pen** dot and trail exist (T-056, `client/overlay/`, display-only, `InputCapture.kt:48`), now **default off** after the user found it unnecessary (T-064, NOTES line 358). Optical input-to-photon latency has never been measured; only the USB input path is known (contact → Mac event median 2 ms, NOTES line 182).
- Corrections: the review describes a "local pen trail" as future work. It exists, was tried, and was turned off by user choice.
- Severity opinion: Low. Run the optical measurement (H05 scope) before building a cursor layer.

### X2 — Key and pen release under disconnect/background
- Verdict: ALREADY ADDRESSED for code and partly on device. The remaining combinations are NOT VERIFIABLE IN CODE.
- Evidence:
  - Code paths: client `releaseAll` on focus/background/device removal (`InputCapture.kt:14-26,249-253`). Host release-all order is pen/buttons → scroll/pinch → keys then modifiers (`InputStateMachine.swift:247-275`). Owed releases are retried forever (`Core/Input/OwedRelease.swift:1-25`). `input_release` and `owed` are logged (`InputController.swift:296-317`).
  - On device (T-025, NOTES lines 182–193): cable pull mid-stroke (`pen_up=1 pen_leave=1`), Home, notification panel, force-stop, keyboard background.
  - Not done: Wi-Fi off mid-stroke, Shift/Ctrl+drag combinations, and "close time" (time from the trigger to the posted release is not logged).
- Corrections: the review does not say most of the matrix is already done.
- Severity opinion: agree that it is needed. Remaining risk is Low.

### X9 — Pen accuracy matrix
- Verdict: NOT VERIFIABLE IN CODE (needs device). Partially covered by T-025.
- Evidence: T-025 acceptance (pressure, hover, eraser via double-tap, palm OK; tilt qualitative only; corners and letterbox not done; "kalan maddeler kullanım sırasında izlenecek"). `InjectTest.swift` exists but its tilt/eraser steps were never run (T-025 "Henüz yürütülmeyen adımlar").
- Corrections: none.
- Severity opinion: Low–Medium.

### X10 — Keyboard/mouse matrix
- Verdict: ALREADY ADDRESSED (mostly). The remaining items need a device.
- Evidence: NOTES line 245 (keyboard and touchpad/mouse), T-103 (relative pointer in games, NOTES line 723), pointer-capture shortcuts (T-035/T-038). Untested: dead keys, keyboard or mouse removal mid-press on device.
- Corrections: none.
- Severity opinion: Low.

### D7 — Validate pen per app
- Verdict: PARTIALLY ADDRESSED
- Evidence: T-025 (closed by user decision, with remaining items monitored in use), decision 0007, and the Krita spike study (NOTES lines 197–222, a Krita smoothing artefact). Still open: tilt directions, a real-dot test, Wi-Fi timing measurement after T-111, apps other than Krita, and a written finger-vs-drawing policy (it exists as decision 0006, so only the "clear policy" exit criterion is met).
- Corrections: the "clear finger-navigation vs drawing policy" exit criterion is already met by decision 0006.
- Severity opinion: agree with the ordering. Wi-Fi pen work stays behind USB per the user's decision.

### A5 — Local cursor / pen trail for perceived latency
- Verdict: ALREADY ADDRESSED for the pen (T-056 overlay, default off per T-064). The local mouse cursor is NOT implemented.
- Evidence: The overlay never sends data: `penInk` is "display only, never affects what is sent" (`InputCapture.kt:47-48,109`). No predicted pressure or strokes go to the Mac anywhere in the code.
- Corrections: the review is unaware of T-056/T-064.
- Severity opinion: Low. Optical measurement comes first.

### L03 (input side) — Display geometry, CGEventSource and cursor queries during injection
- Verdict: PARTIALLY CORRECT
- Evidence:
  - `environment()` runs on **every** input message (`InputController.swift:185,320-338`). It calls `VirtualDisplayLocator.geometry()`, which runs `CGDisplayIsOnline`, `CGDisplayVendorNumber`, `CGDisplayModelNumber`, `CGDisplayBounds` and `CGDisplayCopyDisplayMode` each time (`VirtualDisplayLocator.swift:33-44,67-88`); only the display *ID* is cached.
  - A fresh `CGEventSource(stateID: .hidSystemState)` is built per event (`CGEventPoster.swift:46-49`).
  - Permission is cached for 200 ms (`InputController.swift:341-347`).
  - The live cursor is queried **only for POINTER_REL** (`:192`), warmed at start, and measured: 0.1 µs bench (`CursorLocator.swift:99-102`) and ~5 µs avg in a game session (NOTES line 723).
  - None of the geometry or source costs are measured.
- Corrections:
  - Cursor queries are not on the pen path, and they were measured (T-103).
  - The end-to-end USB input path is contact → Mac event median 2 ms, max 5 ms, with events arriving at the 2.8 ms pen cadence (NOTES lines 170–175, 182). That argues against a large per-message cost.
- Severity opinion: Low. Measure first; optimise only if the per-message cost reaches tens of µs.

### W4 row "Android UI" (input side)
- Verdict: CONFIRMED
- Evidence: Adapter, trackers, `InputOutbox`, `Codec.encode` and `SendQueue.offer` all run on the UI thread (`MainActivity.kt:553-556`, `SessionController.kt:288-293`, `SendQueue.kt:153-164`). Input does not wait for the 100 ms engine tick. `MainActivity.kt` is 2,124 lines.
- Corrections: none. The UI-thread choice is deliberate: PROTOCOL §7 requires one ordered FIFO and a single producer thread.
- Severity opinion: Low (maintainability, L02 scope).

### W4 row "Mac input"
- Verdict: CONFIRMED (deliberate and documented)
- Evidence: The session queue calls `handlers.deliver` → `InputController.deliver` → `queue.sync` (`SessionServer.swift:1471-1474`, `main.swift:156-162`, `InputController.swift:8-14,182`). The doc comment calls this blocking intentional back-pressure. A slow `CGEvent.post` therefore delays the session queue (PONG replies, video control). The input watchdog timer is on the same input queue (`:79-86`).
- Corrections: there is no evidence of slow posts (see L03). It is a design trade-off, not a bug.
- Severity opinion: Low.

### F1 (input/stylus strengths)
- Verdict: CONFIRMED
- Evidence: pressure/proximity/identity (PK1), contact latch (IN6), source ownership (IN7), owed releases that are never dropped (`OwedRelease.swift`), pure state machines with rule-ID tests (`InputStateMachine.swift:27`), and measure-then-revert habits (T-144 revert, T-064 default-off).
- Corrections: none.
- Severity opinion: n/a.

## Additional issues found

1. **Host key auto-repeat runs on through a network stall (inferred risk, not observed).** Repeat is armed at DOWN and stops only on that key's UP, another DOWN, or release-all (`Core/Input/InputStateMachine+Keyboard.swift:83-85,99-106,108-110`). If the stall starts after a KEY DOWN reaches the host but before its UP, the host keeps repeating until the delayed UP arrives or until the 1.5 s heartbeat-silence release-all (PROTOCOL §6). With macOS defaults that can be about 10+ ghost repeats; held Backspace or arrow keys are the worst case. No input watchdog covers keys (PROTOCOL §7 lists only pen/scroll/pinch). Wi-Fi mostly.
2. **PROTOCOL §4 "Kabul edilen davranış" understates the late-input bound.** It names the client queue (1 s) as the bound, but bytes already written to the client's kernel socket buffer have no age limit (`SessionController.kt:641`: only `tcpNoDelay`; `SendQueue.kt:156` checks age at offer only). The real bound is the host's 5 s silence close. Late complete clicks, keys and strokes can replay after a 1.5–5 s stall, past the release-all latch. This is a doc correction plus the M04 freshness item.
3. **The host could measure input age without a wire change.** PROTOCOL §6 lets the host send PING, and the client already answers any PING (`client/session/SessionMachine.kt:280`) using `System.nanoTime` (`SessionController.kt:325`), the same monotonic base as `MotionEvent.eventTime`. The host just never sends PINGs and drops PONGs (`Core/Session/SessionMachine.swift:741-756`).
4. **Pen timestamps have 1 ms resolution and are clamped monotonic against dispatch-time liveness repeats** (`MotionEventAdapter.kt:169,179`; `PenTracker.kt:284,406`). Any host playout must tolerate dt jitter of ±1 ms and dt = 0 runs. Note this is not a bug today.
5. **No record that Wi-Fi pen arrival rhythm was re-measured after T-111** (control connection moved to a BSD socket). The NOTES table (lines 170–178) was measured over Network.framework with the Mac on Wi-Fi. The T-111 handoff asked for this check (T-111 card line 190).
6. **Palm before pen** (PK5 residual): `TouchTracker` sends a press after 40 ms or 16 px (`TouchTracker.kt:140,429-430`). The palm is reported as FINGER (NOTES line 50). No contact-size (`touchMajor`) heuristic exists.
7. **Per-message `environment()` cost is unmeasured** (`InputController.swift:185`; `VirtualDisplayLocator.swift:80-88` calls `CGDisplayCopyDisplayMode` on every message, ~360/s while drawing).

## Proposed work items

### P-M04a — Measure Wi-Fi pen arrival rhythm after T-111 (3 topologies)
- owner: orchestrator (+ user holding the pen). depends_on: [T-111]. Decision record: no. Protocol change: no.
- files: `docs/NOTES.md`, the new card file only.
- Goal: before any host playout work, find out whether Wi-Fi pen clustering still exists now that control runs on a kernel socket, and whether it depends on the Mac's link (Ethernet vs Wi-Fi). This decides whether P-M04c is worth doing.
- Out of scope: code changes.
- Acceptance criteria (all device):
  - [ ] Same 6-fast-circle workload over USB, Mac Ethernet + tablet Wi-Fi, and both on Wi-Fi. Report median, p95 and max inter-event interval and the 0–1 ms share at the Mac (scratch AppKit receiver, `NSEvent.isMouseCoalescingEnabled = false` set *after* launch: NOTES pitfall, line 179).
  - [ ] Client `pen_msgs`/`pen_samples`/`max_batch` and host `input_session_end` for each run.
  - [ ] User's qualitative verdict in Krita (smoothing = None) per topology.
  - [ ] Results table in NOTES, dated, ≥ 3 runs per condition.
- Plan hints: the receiver and the getevent converter were scratch tools (T-025) and must be re-written. Turn Krita smoothing off so the known Krita spike artefact (NOTES lines 210–222) does not confound the result.

### P-M04b — Host: input-age diagnostics via host PING (no wire change)
- owner: mac-host-dev. depends_on: [].
- Decision record: no. Protocol change: **no byte change**. The orchestrator adds one sentence to PROTOCOL.md §6: "host sends PING every 500 ms on the accepted control connection and uses PONG for its own offset estimate (diagnostics only)". The client already answers.
- files:
  - `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift`
  - `host-mac/Sources/MateBridgeCore/Input/InputAge.swift` (new: pure offset estimator + age histogram)
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift`
  - `host-mac/Tests/`
  - the card file
- Goal: make capture-to-injection age visible on the host for PEN and the other timed input messages, so stalls and late replays can be measured instead of inferred (M04, IN8, LM8). Log only aggregates (p50/p95/max age, count over 250 ms), never coordinates or keys.
- Out of scope: acting on age (dropping or reshaping input), playout, client changes.
- Acceptance criteria:
  - [ ] XCTest: the offset estimator picks the min-RTT sample from a window and survives clock skew or backwards jumps (pure, fake clock).
  - [ ] XCTest: age per PEN sample = `hostRecv − (base + dt − offset)`; the KEY/POINTER/SCROLL/PINCH `time_us` age is computed the same way; it is negative-tolerant and reported, not clamped (H05 lesson).
  - [ ] XCTest: SessionMachine sends PING on the accepted connection at 500 ms, handles PONG, and ignores PONG for an unknown seq or another connection.
  - [ ] `input_session_end` plus a once-per-second `input_age` line while input flows: p50/p95/max µs, `late_250ms` count, `offset_rtt_us`.
  - [ ] `./scripts/check.sh` passes.
  - [ ] Device (orchestrator): USB vs Wi-Fi values plausible (USB p50 a few ms).
- Plan hints:
  - Host PING times use `HostClock.nowUs`.
  - The PONG `responder_time_us` is client `nanoTime/1000`, the same base as `eventTime*1000` (both CLOCK_MONOTONIC).
  - PONG rides the same client FIFO as input, so its RTT inflates under congestion; use a min-RTT window (mirror client `ClockSync` logic).
  - Keep it off the injection hot path: compute on the input queue and store into a fixed histogram.

### P-M04c — Host: experimental bounded pen playout for Wi-Fi (behind knob, default off)
- owner: mac-host-dev. depends_on: [P-M04a, P-M04b]. Protocol change: no (uses existing `dt_us`).
- Decision record: **yes**. Draft "0018 — Wi-Fi kalem playout (deneysel)": *The host may delay PEN contact/hover samples so they are injected with their tablet-relative spacing (`dt_us`), with a hard budget of ≤ 12 ms added latency, only on non-loopback connections and only behind `MATEBRIDGE_PEN_PLAYOUT_MS` (default 0 = off). Every state boundary flushes the queue at once: CONTACT 1→0, IN_RANGE→0, tool change, release-all, watchdog, session end, and any non-PEN input message (preserves cross-message order). USB stays immediate. Adopt as default only if optical/visual A/B on Wi-Fi shows a line-quality gain that outweighs the added latency (PLAN Aşama 5 item, user decision 2026-09-30).*
- files:
  - `host-mac/Sources/MateBridgeCore/Input/PenPlayout.swift` (new, pure)
  - `host-mac/Sources/MateBridgeCore/Input/InputPipeline.swift`
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift`
  - `host-mac/Tests/`
  - `docs/decisions/0018-*.md` (orchestrator)
  - the card file
- Goal: remove network-induced clustering of pen events on Wi-Fi without touching USB latency or input safety.
- Out of scope: client changes, CGEvent timestamp rewriting (optional follow-up; NOTES shows Krita's timestamp setting did not matter), smoothing or prediction.
- Acceptance criteria:
  - [ ] XCTest replay: a recorded trace with an injected 30 ms burst gives output spacing within ±1 ms of `dt` where within budget; samples never reorder; stroke boundaries, pressure and position are preserved bit-exactly.
  - [ ] XCTest: CONTACT 1→0, release-all and the watchdog flush immediately. A KEY or POINTER arriving behind queued pen samples is processed only after they are flushed. No up is ever delayed beyond the budget.
  - [ ] XCTest: budget overrun (backlog > budget) collapses to immediate posting, not unbounded delay.
  - [ ] Loopback peer gives playout off (unit-tested decision function).
  - [ ] Device: A/B in Krita on Wi-Fi with P-M04b ages; USB unchanged.
- Plan hints:
  - Use a DispatchSourceTimer on the input queue.
  - Mind `queue.sync` back-pressure: the playout must not block the session queue while waiting.
  - Handle dt = 0 runs and ms quantization (additional issue 4).
  - The pen watchdog (500 ms, receipt-based) is unaffected by a ≤ 12 ms delay.

### P-M04d — Input freshness policy after stalls (decision first)
- owner: orchestrator. depends_on: [P-M04b] (needs real age data). Protocol change: semantics only (PROTOCOL §4/§7 text), no bytes.
- Decision record: **yes**. Draft "0019 — Bayat girdi politikası": *Input whose host-measured age exceeds T_stale (e.g. 300 ms, to be set from P-M04b data) is handled as follows. Hover and relative motion collapse to the newest state. New presses are ignored, together with their matching releases (inert by the existing KEY-DUP, latch and owner rules): PEN `STROKE_START`, POINTER button-down edges, KEY DOWN, SCROLL/PINCH BEGAN. Releases are always applied. If the offset estimate is not trustworthy (RTT spread too high), the policy is off.* Also correct the PROTOCOL §4 "Kabul edilen davranış" bound (additional issue 2).
- files: `docs/decisions/`, `docs/PROTOCOL.md` (orchestrator); a later implementation card for `Core/Input/`.
- Goal: avoid seconds-old clicks, keys and strokes replaying after a Wi-Fi stall, without ever dropping a release.
- Out of scope: implementation in this item.
- Acceptance criteria: [ ] decision accepted by the user, with a threshold justified by measured age distributions; [ ] the PROTOCOL bound text corrected.
- Plan hints: the risk is dropping legitimate input because of an offset error. Make it fail-open (policy off) when the offset is uncertain.

### P-KR — Host: stop key auto-repeat when the control connection goes quiet (additional issue 1)
- owner: mac-host-dev. depends_on: []. Decision record: small update to decision 0003 (orchestrator). Protocol change: semantics only. PROTOCOL §4 KEY host rules gain a fourth stop condition; no bytes.
- files:
  - `host-mac/Sources/MateBridgeCore/Input/InputStateMachine+Keyboard.swift`
  - `host-mac/Sources/MateBridgeCore/Input/InputStateMachine.swift`
  - `host-mac/Sources/MateBridgeCore/Input/InputPipeline.swift`
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift`
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift` (a `noteControlActivity` hook only)
  - `host-mac/Tests/`
  - the card file
- Goal: a delayed KEY UP during a network stall must not produce a train of ghost repeats (deleted text, runaway arrows). Repeat pauses, without generating an UP, when nothing has been received on the control connection for > 600 ms (PING period 500 ms + margin), and resumes on the next received record if the key is still held.
- Out of scope: client keepalives for held keys (alternative needing protocol semantics; mention in the decision).
- Acceptance criteria:
  - [ ] XCTest (fake clock): no repeat is emitted while `now − lastControlActivity > 600 ms`. Repeat resumes after activity; UP and release-all still stop it; no burst after resume (existing one-per-call rule).
  - [ ] `./scripts/check.sh` passes.
  - [ ] Device: hold a key on Wi-Fi and block traffic briefly (e.g. toggle tablet Wi-Fi). At most ~1 extra repeat, then no stuck key.
- Plan hints: the activity timestamp should be updated for every decoded control record (PING included) on the session queue and passed into `InputController` without `queue.sync` re-entry (an atomic, or ride on `deliver`).

### P-PK — Pen and keyboard device validation matrix (PK2, PK3, X2, X9, X10, D7, IN4)
- owner: orchestrator + user. depends_on: []. Decision record: only if the tilt sign is wrong (then a PROTOCOL §4 tilt formula change: protocol owner, both sides plus fixtures). Protocol change: none expected.
- files: `docs/NOTES.md`, the card file (plus `scripts/` only if a recorder tool is versioned, per M07).
- Goal: close the device-only gaps left open when T-025 closed, so pen and keyboard behaviour is documented rather than assumed.
- Out of scope: fixes (each failure becomes its own card).
- Acceptance criteria (all device):
  - [ ] Tilt in 4 directions × 2 landscape rotations (`sensorLandscape`). The Krita Tablet Tester sign matches the physical lean.
  - [ ] Corners + centre: coordinate error < 1 pt, letterbox bands included.
  - [ ] Pressure ramp light to hard is monotonic; a light first touch draws.
  - [ ] 20 real pen dots: none lost (`bounce_dropped` counted vs visible dots).
  - [ ] Hover, eraser and double-tap.
  - [ ] Wi-Fi off mid-stroke, and Shift+drag / Ctrl+drag during USB pull and app background. No ghost down; `input_release` and `owed` lines captured.
  - [ ] Glide keyboard detach while holding a key; dead keys in Turkish-QWERTY-PC.
- Plan hints: `--inject-test` tilt and eraser steps from T-023 were never run (T-025). Record the tablet `getevent` and the Mac CGEventTap listener (scratch) for the dot test.

### P-PALM — Palm-before-pen evidence, then optional contact-size filter (PK4/PK5 residual)
- owner: orchestrator (measurement), then android-client-dev if data supports it. depends_on: []. Decision record: yes, only if a filter is adopted (an amendment to decision 0006). Protocol change: no.
- files (follow-up implementation): `client-android/app/src/main/kotlin/dev/matebridge/client/input/TouchTracker.kt`, `MotionEventAdapter.kt`, `Model.kt`, `client-android/app/src/test/`, the card file.
- Goal: measure how often a palm lands before the pen is in range and gets sent as a click (`palm_reject` vs host clicks), and whether `touchMajor`/`size` separates palm from finger on this panel. Only then decide on a filter, such as "no single-finger press with touchMajor > X", or a "drawing" finger profile.
- Out of scope: API 33 features (FLAG_CANCELED is unavailable on the device).
- Acceptance criteria: [ ] a NOTES entry with the palm vs finger `touchMajor` distribution (probe logging, no coordinates); [ ] a decision for or against a filter. If adopted: [ ] JVM tests for the size gate and its interaction with HOLD_MS, pinch and scroll.
- Plan hints: the existing probe app (T-003) can log `getTouchMajor`/`getSize`. Keep releases unconditional.

### P-L03i — Host: measure per-message injection overhead
- owner: mac-host-dev. depends_on: []. Decision record: no. Protocol change: no.
- files: `host-mac/Sources/MateBridgeHost/Input/InputController.swift`, `host-mac/Sources/MateBridgeHost/Input/CGEventPoster.swift`, `host-mac/Sources/MateBridgeHost/Input/VirtualDisplayLocator.swift` (timing only), the card file.
- Goal: count and time `environment()` (geometry) and `poster.post` per message, the same way T-103 did for cursor queries. Add avg and max µs to `input_session_end`. Optimise only if the numbers justify it: cache geometry until `CGDisplayRegisterReconfigurationCallback`, or reuse one `CGEventSource`. Reusing a source changes event provenance and needs a Krita check.
- Out of scope: the optimisation itself, unless the measurement shows > ~50 µs/message.
- Acceptance criteria: [ ] new counters in `input_session_end`; [ ] `./scripts/check.sh` passes; [ ] device: one 60 s drawing session logged in NOTES.
- Plan hints: use `DispatchTime.now().uptimeNanoseconds` around the calls, as in `liveCursor()` (`InputController.swift:251-260`).

## Coverage

| ID | Verdict entry |
|---|---|
| M04 (sub-points 1–4 + freshness) | yes: CONFIRMED (known/deferred, PLAN Aşama 5) |
| IN1 | yes: CONFIRMED |
| IN2 | yes: CONFIRMED |
| IN3 | yes: CONFIRMED |
| IN4 | yes: CONFIRMED |
| IN5 | yes: CONFIRMED |
| IN6 | yes: CONFIRMED |
| IN7 | yes: CONFIRMED |
| IN8 | yes: CONFIRMED |
| IN9 | yes: CONFIRMED |
| IN10 | yes: CONFIRMED (minor corrections) |
| PK1 | yes: CONFIRMED |
| PK2 | yes: CONFIRMED |
| PK3 | yes: NOT VERIFIABLE IN CODE |
| PK4 | yes: CONFIRMED |
| PK5 | yes: ALREADY ADDRESSED (decision 0006) |
| PK6 | yes: CONFIRMED |
| PK7 | yes: ALREADY ADDRESSED (mostly) |
| PK8 | yes: CONFIRMED (pen trail exists, T-056/T-064) |
| X2 | yes: ALREADY ADDRESSED (partly) |
| X9 | yes: NOT VERIFIABLE IN CODE |
| X10 | yes: ALREADY ADDRESSED (mostly) |
| D7 | yes: PARTIALLY ADDRESSED |
| A5 | yes: ALREADY ADDRESSED (pen) / not done (mouse cursor) |
| L03 (input side) | yes: PARTIALLY CORRECT |
| W4 "Android UI" | yes: CONFIRMED |
| W4 "Mac input" | yes: CONFIRMED |
| F1 (input/stylus) | yes: CONFIRMED |
