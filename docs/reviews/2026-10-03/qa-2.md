# QA-2: cards T-158 … T-175 (HEAD 84c0c4c, read-only)

Totals: **1 blocker, 17 should-fix, 8 nit**. Spot-checked file:line citations in every code card; all checked ones match HEAD unless noted below. All Plan sections are the placeholder.

---

## T-158
1. **should-fix**: the card contradicts itself on `build.gradle.kts`. `files:` (line 14) and the orchestrator note (line 42) allow `testOptions` in `build.gradle.kts`, but the Risk bullet (line 37) says "changing `build.gradle.kts` is outside `files:` (write it under *Açık sorular*…)".
   Fix: in line 37 replace "Choose one in *Plan* and justify it; changing `build.gradle.kts` is outside `files:` (write it under *Açık sorular* if you think it is needed)." with "Choose one in *Plan* and justify it. If neither is enough, `testOptions.unitTests.isReturnDefaultValues = true` in `build.gradle.kts` is allowed (see the orchestrator note); nothing else in that file."

## T-159
1. **should-fix (input safety: false FAULT → RELEASE_ALL mid-stroke)**: the anchor of the "no output for 1500 ms while ≥ 3 inputs" rule is not defined. If the timer is measured from the last output (the existing `lastOutputNs`, `VideoRenderer.kt:544`), then a static screen held for more than 1.5 s, followed by the user starting to draw, faults as soon as 3 frames are queued and the first output is still pending. That is exactly when a pen is going down. Separately, if inputs are counted cumulatively per generation rather than since the last output, a single input after idle trips the rule.
   Fix: in the acceptance and the 0019 summary, write "no output while **≥ 3 non-config inputs have been queued since the last output and the oldest of them was queued ≥ 1500 ms ago**". Add a JVM case: idle 10 s, then 3 inputs within 30 ms and the first output 20 ms later → stays HEALTHY.
2. **should-fix (input-state behaviour change not pinned down)**: "a new generation is STARTING until its first output" does not say what a generation is or whether STARTING closes input. As written, every mode change, surface re-attach and in-attachment `decode_error` restart (`VideoRenderer.kt:353`) would run `setActive(false)` → `RELEASE_ALL(USER)` and cut strokes or held keys.
   Fix: add to the acceptance: "Generation = one `attachSurface`/`reconfigure` call (new config or new surface). STARTING closes input (`inputAllowed = false`, with the normal releases). A codec restart after `decode_error` inside the same attachment is NOT a new generation: input stays open and only the FAULT rules apply. A JVM test pins both cases."
3. **should-fix (the change as written has no effect; file missing)**: resetting `frames` in `SessionMachine.kt` on reconnect or migration does nothing on its own. Every `Tick` overwrites it with `frames = videoFrames` (`SessionMachine.kt:353`), and the controller's `videoFrames` is reset only on `Event.Start` (`SessionController.kt:358`). The panel would hide again on the next UI tick with the old count. Also, the JVM test for this lives in `CT/session/SessionMachineTest.kt` / `MigrationTest.kt`, which are not in `files:`.
   Fix (pick one, state it in the card): (a) drop the `SessionMachine.kt` change, because input is already closed by VideoHealth (a reconnect re-attaches and a migration reconfigures, both creating a STARTING generation), and test that path instead; or (b) add `C/session/SessionController.kt` (reset `videoFrames` on the same paths) plus `client-android/app/src/test/kotlin/dev/matebridge/client/session/SessionMachineTest.kt` and `MigrationTest.kt` to `files:`.
4. **should-fix (device evidence for X3 cannot be produced)**: the injected fault fires at launch ("one-shot per launch"). For `create`/`configure`/`silent` the first generation never becomes HEALTHY, so input never opens. T-164 then cannot "hold Shift and keep the pen down while the fault fires".
   Fix: add "The fault is armed at launch but fires on the first codec generation that starts after the stream has been HEALTHY for `--ei decoder_fault_after_s N` seconds (default 10): `dequeue`/`silent` hit the running codec, and `create`/`configure` hit the next restart. Log `ev=decoder_fault mode= armed_s=` once."
5. **should-fix (consistency with T-161 and 0019)**: decision 0019 lists "the teardown wait times out (M03)" as a fault. T-161 is told to "report FAULT(stuck) to VideoHealth", but T-159's acceptance gives VideoHealth no such input. T-161 has neither `VideoHealth.kt` nor `MainActivity.kt` in `files:`.
   Fix: add the acceptance item "`VideoHealth` takes a generic `fault(cause)` input with causes `give_up|no_output|not_running|stuck` (`stuck` is unused until T-161), wired from a single renderer callback (`onHealthEvent`), so T-161 only calls it."

## T-160
1. **blocker**: the item "`currentConfigId` is reset to -1 on CloseVideo/CloseControl" breaks video on every config. `onConfig` emits `ApplyConfig(cfg)` → `CloseVideo` → `OpenVideo` in that order (`SessionMachine.kt:347-349`). A reset on CloseVideo wipes the config just applied (`SessionController.kt:466-467`), so the new reader's `hello.configId == currentConfigId` never matches and nothing is delivered. A video-only reconnect (`SessionMachine.kt:371`, same config) has the same problem.
   Fix: replace the acceptance line and the Plan hint with "`currentConfigId` is reset to -1 on CloseControl and session loss (`closeAll`/`lose`), **not** on CloseVideo: `onConfig` emits ApplyConfig → CloseVideo → OpenVideo (`SessionMachine.kt:347-349`). Generation safety comes from the gate's `videoGen`. JVM test: the action sequence of a STREAM_CONFIG leaves the new reader deliverable."
2. **nit**: the "never blocks while holding the gate lock" note omits one path. `FrameQueue.offer` can call `onKeyframeRequest` → `controller.trySend` → `SendQueue.send` (`Codec.encode`, and `onOverflow` on the first overflow; `SendQueue.kt:82-89`).
   Fix: add "…and `offer` may call `onKeyframeRequest` → `controller.trySend` → `SendQueue.send`; confirm that it takes no lock the engine thread holds while calling `abort()`, or move the request out of the locked section."

## T-161
1. **should-fix**: reporting FAULT(stuck) needs a VideoHealth input and its MainActivity wiring, and neither file is in `files:`. Fix: preferably resolve via T-159 #5. Otherwise add `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt` and `…/MainActivity.kt` (the renderer callback wiring only) to `files:`.
2. **nit**: the 100/500/1000 ms restart backoff runs on the decoder thread. A plain `Thread.sleep(1000)` would make `detachSurface`'s 300 ms join time out (`detach_slow`). Fix: add "the backoff wait is woken by `retire()` (`att.active=false`), e.g. by parking on the attachment, so `detachSurface` stays ≤ `JOIN_MS` during a backoff; JVM test."

## T-162
1. **should-fix**: "(or `sync` if teardown must wait)" (Plan hints) contradicts the acceptance "never on a Swift cooperative thread". `VideoPipeline.teardown` is `async` (`VideoPipeline.swift:279-283`). A `submitQueue.sync` there blocks a cooperative thread, and GCD usually runs a sync block on the calling thread anyway.
   Fix: replace it with "`stop()` always enqueues the teardown block with `async`. If `VideoPipeline.teardown` must wait, it awaits a `withCheckedContinuation` resumed at the end of that block."
2. **should-fix**: `stop()` is reached from `deinit` (`HEVCEncoder.swift:681`). An async teardown block that captures `self` from deinit is a Swift runtime trap ("object retained during deinit"). Fix: add "the owner-queue teardown block captures only the session/backend and local values, never `self`."
3. **should-fix (R-tag test must exercise production code)**: Step 1 moves only "the reserve / take-pending / stopped decision" into Core. The inversion happens in the unlock-then-`perform`/`send` sequence (`HEVCEncoder.swift:321-324, 488-491, 612-619, 649-655`), so a red test against the decision alone would test the harness, not the code.
   Fix: replace it with "Step 1 moves the whole offer → reserve → unlock → `backend.encode` sequence (today's `perform`/`releaseSlotAndDrain`/`flushPending` dispatch) into `EncoderSubmitOrder`, so the barrier test drives production code."
4. **nit**: MateBridgeCore imports only Foundation/Dispatch/Darwin/CryptoKit. Fix: add "`EncoderSubmitOrder` is generic over the frame and session payload; no CoreMedia/VideoToolbox import in Core."

## T-163
1. **should-fix (unattainable device criterion)**: "at most ~1 extra repeat after the stall begins" does not follow from the design. The 600 ms silence threshold measured from the last received record (PINGs every 500 ms) allows repeats for up to 600 ms after the last record, i.e. up to ⌈600/83⌉ ≈ 7 at macOS defaults (average ~4). Today's worst case is ≈ 18 (1500/83). The same text is in the manifest.
   Fix: "The Mac shows at most ~7 repeats after the stall begins (≤ 600 ms of repeat at the macOS interval; today up to ~18). Count the deleted characters, and record `repeats=` from `input_session_end`."
2. **should-fix**: "update the timestamp for every decoded control record" at `SessionServer.swift:1237` would count records from every connection, including pending or unauthenticated ones and a T-096 migration candidate on USB while the Wi-Fi session is stalled. That keeps ghost repeat alive in exactly the stall case.
   Fix: "only records of the connection whose input is delivered (the active session) update `lastControlActivity`; XCTest or Handoff shows the filter."
3. **nit**: the 2 s Wi-Fi toggle crosses the 1.5 s heartbeat release, so the device run never exercises "repeat resumes after a short stall" or the `queue.async { rearmWatchdog() }` edge. Fix: "Handoff states that resume-after-stall is covered only by XCTest (a sub-1.5 s stall is not reproducible by toggling Wi-Fi)."

## T-164
1. **should-fix**: Procedure A step 2 starts the app with the fault, which fires before input ever opens (see T-159 #4), so step 3 ("holds Shift … while the fault fires") is impossible for every mode.
   Fix: "Start with `--es decoder_fault <mode> --ei decoder_fault_after_s 15`. Connect and wait until the image is HEALTHY. The user holds Shift and keeps the pen down before second 15. For `create`/`configure`, trigger the restart with a mode change after arming, and measure only recovery, because input is already closed by STARTING."

## T-165
1. **should-fix**: other test files assert today's `DisplayLease` results: `StreamPrefsTests.swift:148-150` (`sessionEnded` then `[.reuse]`) and `BitratePrefsTests.swift:83,98`. If the parked return path becomes a new action (the card allows "new action or flag"), those tests break and are not in `files:`.
   Fix: add `host-mac/Tests/MateBridgeCoreTests/Video/StreamPrefsTests.swift` and `BitratePrefsTests.swift` to `files:`, or state "same-device return from park keeps returning `[.reuse]`; the coordinator knows the display is parked."
2. **nit**: `final class DisplayLeaseTests` already exists in `IntegrationTests.swift:39`. A new `DisplayLeaseTests.swift` must not redeclare it. Fix: "extend the existing `DisplayLeaseTests` class (or name the new file's class `DisplayParkTests`)."

## T-166: OK

## T-167: OK

## T-168
1. **should-fix**: `is_hw`/`sw_only` need `codecInfo.isHardwareAccelerated`/`isSoftwareOnly`. After T-158, the renderer reaches the codec only through `DecoderCodec`, whose interface is "nothing the renderer does not already call". The interface (and T-159's decorator `DecoderFault.kt`, unless it uses `by` delegation) must grow, and neither file is in `files:`. Fix: add `client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderCodec.kt` and `…/video/DecoderFault.kt` to `files:` ("diagnostic accessor only").

## T-169
1. **should-fix**: the stats log line is per log window (10 s, T-141), so ">5 s mismatch" cannot be judged from it. The per-second `vsync` p50 is computed in `statsTick` (`MainActivity.kt:1390`), which the card does not allow touching.
   Fix: "`MainActivity.kt` may be touched only in `statsTick` (the per-second `RefreshMismatch` feed), the stats log line, and the `applyRefreshRate` logging."

## T-170
1. **should-fix**: the plan stamps `session_id`/`config_id` at pipeline construction (`StreamCoordinator.swift:580`). The pipeline outlives sessions (lease `.reuse` across a reconnect today; reuse after park with T-165), so later sessions get the wrong `session_id`. The per-connection values are at the `VideoSender` construction (`StreamCoordinator.swift:425-429`, `link.sessionID`/`link.configID`).
   Fix: "Stamp `session_id`/`config_id` in the sender's `trace:` closure at `StreamCoordinator.swift:425-429` (or pass them to `VideoSender`). Touch `StreamCoordinator.swift` only there; `VideoPipeline.swift` then needs no change."

## T-171: OK

## T-172
1. **nit**: `docs/decisions/0021-capture-timestamp-semantics.md` (status *önerildi*) and its README row (`docs/decisions/README.md:45`) already exist. Also, "must be accepted by the user before work starts" conflicts with procedure step 2 (acceptance happens inside the card).
   Fix: step 2 should read "Update the existing 0021 draft with the T-170 data and the chosen option, set the README row status, get user acceptance". Amaç should read "Steps 3–5 start only after the user accepts 0021."

## T-173: OK

## T-174
1. **nit**: Bağlam cites T-169's `target_hz`, but T-169 is not in `depends_on`. Separately, `files:` has no path for the optional counting script or frame-index CSV.
   Fix: "(T-169's `target_hz` if landed; otherwise `display_mode requested_hz`)". Add `tools/measure/optical/` instead of only its README.

## T-175
1. **nit**: the Amaç is about session-queue blocking, but `deliver_us` is not defined. Timed inside `queue.sync`, it misses the wait for the input queue (watchdog or poll running).
   Fix: "`deliver_us` = the caller-side duration of `input.deliver` (around `queue.sync`, including the queue wait); `env_us`/`post_us` are measured inside."
