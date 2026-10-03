# Verifier B — Android client video health, decoder lifecycle, generations

Scope: H02, M01, M03, W1 (client half), V6–V10, SE3, SE4, SE7 (M01/M03 parts), X3, X4, X6, D3 (client parts), F2 (video-health and decoder ownership/generation parts), A1 (client half).
Code at HEAD a30c769. Paths are abbreviated as follows:
- `VR` = client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
- `FQ` = .../video/FrameQueue.kt
- `MA` = .../client/MainActivity.kt
- `SC` = .../session/SessionController.kt
- `SM` = .../session/SessionMachine.kt
- `IC` = .../input/InputCapture.kt

## Verdicts

### H02 — Decoder give-up is only logged; input stays live on a frozen/black image
- Verdict: CONFIRMED
- Evidence:
  - `VR:341-355` `decodeAttempts`: after `RestartPolicy` (`RestartPolicy.kt:4`, 3 restarts per 10 s) is exhausted, it logs `ev=give_up`, sets `att.active=false`, calls `onGiveUp`, and the decoder thread exits. `current` is NOT cleared and `attached` stays `true` (`VR:197-199`, only `detachSurface` clears it).
  - `MA:1154`: `onGiveUp = { why -> MbLog.e("decoder_give_up", ...) }`, and nothing else happens.
  - `MA:643-649` `syncInputActive`: `on = settingsPanel.inputAllowed(started && !isDestroyed && panel.visibility == GONE && !viewport.isEmpty)`. No decoder or video term. The panel is hidden by `MA:1884` `streaming = state is Connected && state.framesReceived > 0 && renderer != null`, and `framesReceived` counts frames *received on the video TCP socket* (`SC:842`), not decoded ones.
  - Other paths that could release input or reconnect after give-up. I checked each one, and none of them fires:
    - (a) DECODE_ERROR keyframe requests: these are sent only while restarts are still allowed (`VR:353`), plus on frame_too_large (`VR:458-463`). They never touch input.
    - (b) Host heartbeat silence: control PING/PONG keeps flowing (`SM` onTick), so the session is healthy.
    - (c) StallDetector: diagnostics only, and opt-in (T-142).
    - (d) Host STATS: the host decodes `framesDecoded` (`MateBridgeCore/Message.swift:193`) but nothing reacts to it.
    - (e) Release paths: onPause/focus/device-detach/panel (`MA:620,632`, `IC:254`) are lifecycle-only.
  - The only recovery triggers are a surface re-create (`attachSurface`, e.g. background→foreground, which restarts the whole session anyway), a new STREAM_CONFIG (`reconfigure`, e.g. the user changes mode), or a user disconnect/reconnect. All of these need the user to act.
  - Side effect: after give-up the queue is still fed (`MA:503-507` checks only `attached`). With motion, `FQ` overflows, sends FRAMES_DROPPED, then the `takeRetry` STARTUP every 500 ms (`MA:1373`, `FQ:258-267`). STARTUP makes the host resend CODEC_CONFIG plus a forced IDR (T-030). The result is a sustained stream of about 2 IDR/s while the image is frozen. See Additional issue 1.
- Corrections:
  - The review covers only the *exception* path. The device-proven failure mode is quieter: T-028 (`backlog/tasks/T-028-*.md` "Bilinenler") showed `codec_start` with no `output_format` and `recv=59 dec=0`. The codec ran without error and produced nothing ("Kontrol ve girdi çalışıyor, görüntü yok"). No exception means no give-up. A health signal must also cover "input queued to the codec but no output for N ms" and "decoder thread not running while attached", not only `onGiveUp`.
  - Another real frozen-image-with-live-session case is T-132 (host sleep), but that one is host/session level.
  - The review says input is not gated on the first image of a new generation. That is correct, and the gate is even looser than it states. `SM:175` resets `frames` only on `Event.Start`. On an automatic reconnect (lose → WAIT_RETRY → openControl) the old count survives, so `SM:317` emits `Connected(hostName, frames>0)` on ACCEPTED. Input therefore re-opens once the viewport is valid (STREAM_CONFIG → `layoutVideo`), before any frame of the new session is received or decoded.
- Severity opinion: agree with High for "daily main screen". The frequency of give-up on this device is unmeasured: NOTES has no `decode_error`/`give_up` line, and T-013 open question (3) says the restart/detach_slow paths were never exercised on device. The silent no-output case already happened once (T-028).

### M01 — Video reader does not validate session/video generation at delivery
- Verdict: CONFIRMED (the mechanism is exactly as described). The practical frequency of cross-session leakage is low.
- Evidence:
  - `SC:837-844`: `if (hello.configId == currentConfigId) listener.onVideoFrame(msg)`. There is no `video === this` / `gen` check, unlike the control reader's audio pre-filter `if (control !== this) return` (`SC:749`).
  - `SC:803-806` `abort()` only sets `closedPosted` and closes the socket. The inner `while (true) { decoder.next() ... }` (`SC:837-845`) keeps draining every complete record already buffered (up to `READ_CHUNK` = 64 KiB per read, `FrameDecoder.kt:122`). A delivery already inside `onVideoFrame` also completes. Frames can therefore be delivered after `CloseVideo`/`OpenVideo` returned on the engine thread.
  - Same configId across sessions is not just possible, it is the norm. The host's first config of every session is the constant `StreamCoordinator.configID = 1` (`host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:14, :202`). It only increments within a session (`:381`). On the client, `currentConfigId` is written only in `ApplyConfig` (`SC:466-468`) and is never reset on CloseVideo/CloseControl/lose. Any leftover frame of session N (config 1) therefore passes the check in session N+1 (config 1). Across sessions the check is effectively a no-op.
  - Config not yet applied in UI: `ApplyConfig` sets `currentConfigId` on the engine thread and then `onStreamConfig` posts `installConfig` to the UI (`MA:499`). In the same dispatch, `CloseVideo` + `OpenVideo` (`SM:340-350`) start the new reader. New-config frames that arrive before the UI runs `reconfigure` go into the shared `FrameQueue` and are consumed by the *old* codec. `reconfigure` then wipes them with `queue.reset(keepConfig=false)` (`VR:243-253`). This is exactly the T-028 incident. It was healed on the host side by T-030 (config resend on STARTUP). The client-side ordering was left as an open question in T-028/T-030 ("Faz 4 temizliğine aday") and never got a card.
  - Mitigations the review did not credit:
    - (1) On a normal reconnect `render(Disconnected)` → `releaseRenderer()` → `detachSurface()` sets `attached=false` (`MA:1883, 1188-1189`), and `onVideoFrame` drops frames while detached (`MA:504`). A leaked old frame would have to arrive more than 1 s later (the backoff), after the new `installConfig`.
    - (2) After `reconfigure`, the queue gate is closed, so a stray old P-frame is dropped. Only a stray old keyframe or CODEC_CONFIG does harm: the keyframe opens the gate, and the CODEC_CONFIG replaces `lastConfig`.
    - The realistic exposure is T-096 migration. There `promote` closes the old video (`SM:498`) but the UI stays `Connected`, so the renderer stays attached, and the new STREAM_CONFIG arrives one RTT later.
  - The "new renderer" is really the same `VideoRenderer` object for the app's lifetime (`MA:1151-1167`, `VR:30`) with a shared `FrameQueue` (`VR:169`). The generation boundary must be enforced at the queue/renderer, not by swapping objects.
- Corrections: The impact list is right. Add that across sessions the configId check gives zero protection, not just "can pass". Also note that "short corruption" is unlikely on a same-resolution migration, because the old keyframe usually comes from the same encoder (display reused). With a resolution change it would cause a decode error, which counts toward give-up.
- Severity opinion: Medium as a contract and test gap. The practical rate is Low. The in-session ordering race (T-028 class) is the most likely trigger and is currently self-healing only because of the host-side T-030.

### M03 — Missing time/ownership contract for decoder teardown
- Verdict: CONFIRMED (the code matches every cited point). The "close vs output access" consequence is partially mitigated by the framework.
- Evidence:
  - `VR:263-272` `retire(wait)`: sets `active=false`, `current=null`, `lingering=thread`; it joins `JOIN_MS=300` only for `detachSurface` (UI thread), and on timeout logs `detach_slow` and continues. `attachSurface`/`reconfigure` use `wait=false`.
  - `VR:328` `try { att.previous?.join() }`: the next generation waits with **no timeout** and **no log**. Each new attachment waits on the previous *decoder* thread. If an old thread hangs inside native `stop()/release()` or `createCodec`, every later attachment parks behind it, giving a chain of threads with one per surface churn or config change. Meanwhile `attached=true`, frames are queued with no consumer, input is live, and the keyframe requests from the H02 side effect continue.
  - `VR:482-489` `runCodec.finally`: `outRunning=false` → `outThread.join(500)` → `adaptive=null` → `codec.stop()` → `codec.release()`, called whether or not the output thread has exited.
  - Can stop/release race with the output thread's `dequeueOutputBuffer`/`releaseOutputBuffer`? Normally no. The output thread's blocking wait is bounded at ≤20 ms (`VR:415-417`, `IdleWait.IDLE_WAIT_NS` in `VsyncIdle.kt:151`), and `SlotReleaser` never blocks. The join therefore returns in about 20 ms, and the overlap happens only if the output thread is stuck in a native call for more than 500 ms. In that case, calls after `stop/release` throw `IllegalStateException`. The output thread's `catch (e: Exception) { if (outRunning.get()) ... }` (`VR:425-426`) swallows them, so no crash is expected from the Java layer. Vendor HAL behaviour is unknown (needs device).
  - Missed by the review: the next generation joins only the previous *input/decoder* thread, never the previous *output* thread. In the timeout case a straggler output thread keeps running into the next codec generation and mutates renderer-wide state:
    - `lastOutputNs` and `formatChanged` (`VR:493-495`) are plain non-volatile fields;
    - `gauge`, which is reset by the new generation at `VR:384` and then decremented by the old thread;
    - `stats`, `counters`, `firstOutput` (the old thread can consume the new generation's bypass);
    - `readyByPts`/`captureByPts`.

    The same applies within one attachment: `decodeAttempts` (`VR:343-344`) starts the next `runCodec` right after the previous one's 500 ms join timed out.
  - Restart without backoff: `decodeAttempts` retries immediately. If a stuck old codec still holds the hardware decoder instance, `createCodec` can fail 4 times within milliseconds, leading to give-up. That is the M03 → H02 link.
- Corrections: The review says stop/release "overlap" output access. That is true at the API-call level, but the Java framework turns it into caught exceptions. The more concrete risks are the unbounded `previous.join()` and the unjoined straggler output thread sharing renderer fields. Nothing has been reproduced on the device (T-013 open question 3).
- Severity opinion: Medium agreed. It is low-probability but has no recovery except an app restart, and there is no visible state.

### W1 — Video chain description (client half)
- Verdict: CONFIRMED (one wording nit)
- Evidence: reader `SC:808-859` (TCP → `RecordDecoder` → `VideoFrame`) → `MA:501-508` → `VideoRenderer.onFrame` → `FrameQueue.offer` (`VR:223-225`) → input thread `queue.awaitNext` → `queueInputBuffer` (`VR:438-478`) → output thread → pacer → `SlotReleaser` → `releaseOutputBuffer(idx, renderNs)` onto the SurfaceView surface, or onto the GL presenter's decoder surface when `--es render gl` is set (`MA:1095-1109`, experimental with fallback `MA:1118`).
- Corrections: MediaCodec runs in *synchronous* buffer mode driven by two app threads (input `mb-decoder` and output `mb-decoder-out`). It is not the MediaCodec async-callback mode. "FrameQueue protects the reference chain" is correct: it uses a keyframe gate after any drop (`FQ:7-22`).
- Severity opinion: n/a (descriptive).

### V6 — Receive stage
- Verdict: CONFIRMED
- Evidence: `SC:827-845`: blocking `read` (64 KiB) → `RecordDecoder.feed/next` (`security/Records.kt:249-300`) accumulates complete records, checks the length cap before buffering the payload, runs the GCM open (`openPlain`), then `Codec.decodePayload`. The single-fragment rule is enforced at `protocol/Codec.kt:371-373`. Decryption runs on the reader thread.
- Corrections: none.
- Severity opinion: n/a.

### V7 — Decode queue depth
- Verdict: CONFIRMED
- Evidence: `FQ:36,43-47`: `depthForFps = ceil(fps*64/1000)` clamped to 2..8, which gives 4 at 60 fps and 8 at 120 fps (144 fps is clamped to 8, about 55 ms). There is no age or deadline drop; overflow drops all pending frames and closes the gate (`FQ:145-165`). Extra holding outside the queue: one `held` frame on the input thread (`VR:444-455`), plus one prefetched input buffer (`InputBufferSlot.kt`), plus the codec's internal buffers, plus at most one held output (`SlotReleaser`).
- Corrections: none.
- Severity opinion: agree (measurement item, not a bug).

### V8 — MediaCodec threads and maxInFlight
- Verdict: PARTIALLY CORRECT
- Evidence: `maxInFlight` defaults to 0, meaning unlimited (`VR:89`, `MA:223` `inflightLimit=0`; the experiment knob is `--ei inflight N`). `InFlightGauge.canQueue` (`SlotReleaser.kt:162-163`).
- Corrections:
  - The threads are synchronous-mode threads, not "async".
  - "No app-level limit" does not mean unbounded. Codec occupancy is bounded by the codec's own input-buffer count: `inSlot.take(4000)` fails, the frame is held, and the FrameQueue fills, overflows and resyncs. Output is bounded by one held buffer plus the render timestamps the pacer queues ≤1.5 periods ahead.
  - Waiting time *can* accumulate up to these bounds, and no stage reports its age. That part of the review is fair.
- Severity opinion: Low; a measurement item.

### V9 — Render stage
- Verdict: CONFIRMED
- Evidence: `AdaptivePacer.kt` header (D ≤ 1.5 periods; phase lock), `SlotReleaser.kt:20-96` (one replaceable held buffer, one release per vsync slot), `VR:551-574`. `ConstantPlayoutPacer` and `FramePacer` are alternate experiment modes (`VR:377-379, 559-561`).
- Corrections: There are three pacers plus a bypass (`FirstOutputBypass`), not just AdaptivePacer.
- Severity opinion: n/a.

### V10 — Measure queues together; keep gate/overflow→resync/coalescing
- Verdict: CONFIRMED (the recommendation matches the current design; already addressed by T-121/T-122)
- Evidence: keyframe gate, overflow→drop-all→FRAMES_DROPPED, and the 500 ms request hold-off with deferral (`FQ:7-22, 110-177, 286`). T-122 coalesces requests on the host (NOTES 2026-10-02 ~11:35: "fırtına yok", `overflows=0`). The NOTES lines cited (~904-939) match. Per-stage *age* is not exported. Only counters exist (`kf_req/kf_held/overflows/max_pending`, `VR:217-221`) and the opt-in PaceTrace (T-069/T-073).
- Corrections: none. The "age + occupancy per stage" part is new work (overlaps H05/LM8; not my area).
- Severity opinion: agree (keep as is).

### SE3 — Reconnect/state recovery (client half)
- Verdict: CONFIRMED, with one gap (video)
- Evidence:
  - Input: `onConnectionGen` → `capture.onSessionReset()` (`MA:523-532`); `trySendInput` checks the generation (`SC:290-295`); `dropConnection(gen)` (`SC:311-315`).
  - Audio and clipboard check generations (`SC:367, 749-751`; `MA:520, 539`).
  - Video has only the configId check (`SC:843`), which is ineffective across sessions (see M01).
  - Video connections do carry a `gen`, but it is used only for the close event (`SM:240`).
- Corrections: The review lists "video config ID" as a recovery strength. On the client it does not protect across sessions (host configID always starts at 1).
- Severity opinion: n/a (descriptive); the gap is M01.

### SE4 — "TCP connected" ≠ "decoding" ≠ "current image" ≠ "input safe"
- Verdict: CONFIRMED
- Evidence:
  - On the client these collapse into one state. Input is gated by Connected + `framesReceived>0` (received over TCP, `SC:842`, not reset on auto-reconnect, `SM:175/317`) + a laid-out viewport (`MA:643-649, 1884`).
  - A static screen legitimately sends no frames: host idle refresh is opt-in (`MATEBRIDGE_IDLE_REFRESH_MS`, `HEVCEncoder.swift:29-30`, T-086/T-087). A blind "no frame for N s" watchdog would therefore be wrong, which matches the review.
  - Usable signals that exist today:
    - `stats.decoded` vs `received`/inputs (`VideoStats`);
    - `gauge.current()` (in-codec count) and `lastOutputNs`;
    - the decoder thread being alive while `attached`;
    - `onGiveUp`.
- Corrections: Give-up is not the only uncovered case. "Frames queued but no output" (T-028) and "previous thread never exits" (M03) also need to be covered.
- Severity opinion: High (same item as H02).

### SE7 (M01/M03 parts) — Concrete race points
- Verdict: CONFIRMED. See M01 and M03. The M02 part is not in my scope.
- Evidence: `VR:328` (unbounded join), `VR:482-489` (stop/release after the bounded join), `SC:837-845` (no delivery generation).
- Corrections: Add the unjoined straggler *output* thread sharing renderer-wide fields (M03).
- Severity opinion: Medium.

### X3 — Video terminal error injection test
- Verdict: CONFIRMED as a gap: no such test exists, and it is not possible today without refactoring.
- Evidence: `VR:277-325` calls `MediaCodec.createDecoderByType` directly; there is no codec factory seam. The only JVM tests are for FrameQueue/RestartPolicy (`app/src/test/.../video/VideoTest.kt:25-166`). There is no `androidTest` tree.
- Corrections: Split the work. The health state machine and the RELEASE_ALL gating can be JVM-tested once extracted as pure Kotlin. Real create/configure/dequeue injection needs a small `DecoderCodec` interface with a fake, or a debug-only fault-injection extra on the device.
- Severity opinion: agree. It is a prerequisite for closing H02.

### X4 — Old reader race test (zero old frames to new renderer)
- Verdict: CONFIRMED as a gap: no test exists (`grep VideoConn|currentConfigId` in src/test finds nothing).
- Evidence: The delivery logic is inline in the private inner class `VideoConn` (`SC:790-860`), which a test cannot easily drive.
- Corrections: This can be a deterministic JVM test if the delivery gate is extracted into a pure class (see the M01 work item).
- Severity opinion: agree.

### X6 — Surface churn soak (threads/codec/native memory back to baseline)
- Verdict: NOT VERIFIABLE IN CODE (needs device)
- Evidence:
  - The code path is: churn → `retire` + a new thread per attach (`VR:227-260`).
  - Thread count stays bounded only if every old thread exits. With a hung native call they chain (M03).
  - Codec instances are released in `finally` (`VR:486-487`).
  - The `traceWriter` executor is lazily created once (`VR:102-104`), not per churn.
- Corrections: none.
- Severity opinion: Medium as a measurement item (owner: user/orchestrator).

### D3 (client parts) — Stop input on frozen image; M01 boundary; M03 waits
- Verdict: CONFIRMED (sound plan)
- Evidence: As in H02/M01/M03. Order the client work as: (1) the video health gate on input (H02/SE4), (2) the delivery barrier (M01), (3) bounded teardown with per-generation state (M03). Item 3 feeds item 1 through a "stuck" health signal.
- Corrections: Add the "no output while fed" detector (T-028 class) to the exit criteria, and add a "first decoded output of the new generation before input opens" criterion.
- Severity opinion: agree.

### F2 (parts) — Video health tied to TCP; encoder/decoder ownership & generation contract
- Verdict:
  - Video health derived from the TCP connection: CONFIRMED (client).
  - Decoder ownership and generation contract: PARTIALLY CORRECT. A contract exists, but it has holes.
- Evidence:
  - Health: `framesReceived` (TCP receive count) drives the streaming/input gate (`MA:1884`, `SC:842`).
  - Ownership: per-attachment token `Attachment.active` and the join chain (`VR:185-191, 255-272, 328`) do exist. The holes are the unbounded wait, the unjoined output thread, the renderer-wide mutable fields shared across generations, the shared FrameQueue with no generation tag, and no delivery generation.
- Corrections: "Missing" is too strong for the decoder. "Incomplete" is accurate.
- Severity opinion: agree that a narrow redesign is enough. No rewrite is needed.

### A1 (client half) — SessionOwner / MediaOwner on the client
- Verdict: PARTIALLY CORRECT (reasonable as a direction; most of the seams already exist)
- Evidence:
  - `SessionController` and `SessionMachine` already act as the SessionOwner: generations, `inputAllowed`, release, health via PONG timeout.
  - `VideoRenderer` is most of a MediaOwner on the decoder side.
  - What is missing is a small owner for *video health*. Today it is spread across `MainActivity` (2124 lines): the `syncInputActive` gate, `onGiveUp`, the ticker retry, and `render()` with `framesReceived`.
  - `VideoConn` lives inside `SessionController`, which is fine. Only its delivery needs a generation token.
- Corrections: A new framework or a move of `VideoConn` is not needed. A pure-Kotlin `VideoHealth` state machine plus a delivery token is the minimal client "MediaOwner" seam. It also matches L02's suggestion to separate VideoHealth from MainActivity.
- Severity opinion: n/a (architecture direction). Agree with "no new framework/DI".

## Additional issues found

1. **Keyframe request loop while the decoder is dead (H02/M03 side effect).**
   - After give-up (`VR:347-351`), or while a new generation is parked on `previous.join()` (`VR:328`), `attached` stays true and frames keep entering `FrameQueue`, which has no consumer.
   - Under motion, the queue fills, overflows, sends FRAMES_DROPPED (500 ms hold-off) and closes the gate. The ticker's `takeKeyframeRetry` (`MA:1373`) then sends STARTUP every 500 ms, and STARTUP makes the host resend CODEC_CONFIG plus force an IDR (T-030). The keyframe re-opens the gate and the cycle repeats.
   - The result is about 2 forced IDRs per second at 2800×1840 for as long as the image is frozen. This is the bandwidth/audio pattern of the 2026-10-02 keyframe storm (NOTES ~904-918), at a lower rate.
   - A terminal video state should stop feeding the queue and stop the retries.
2. **Input re-opens before the new session's first frame on automatic reconnect.**
   - `SM:175` resets `frames` only on `Event.Start`. An auto-reconnect (`lose` → `openControl`) keeps the old count, and on ACCEPTED it emits `Connected(hostName, frames>0)` (`SM:317`). The panel then hides (`MA:1884-1886`) and input opens as soon as the viewport is valid, without waiting for the new generation's first received frame, let alone a decoded one.
   - The migration path behaves the same way (`promote` → `onAck`, `SM:504-510`).
   - The user can send pen/keys while looking at a stale or black surface for the keyframe round trip (~50–200 ms typical, longer if the decoder fails).
3. **Straggler output thread mutates shared renderer state (M03 detail).** `lastOutputNs`/`formatChanged` are non-volatile instance fields (`VR:493-495`). `gauge`, `firstOutput`, `stats` and the PTS maps are renderer-wide. The next `runCodec` and the next attachment join only the previous input thread (`VR:328`; `VR:343-344` restarts immediately). There is also no backoff between restarts in `decodeAttempts`, so a codec slot still held by a stuck instance can burn the 3-restart budget in milliseconds.
4. **T-028 client ordering never carded.** T-028 "Açık sorular" and T-030 "Kapsam dışı" both deferred "the tablet must apply STREAM_CONFIG before opening the video connection (PROTOCOL §3 step 5)". There is no follow-up card in backlog/tasks. It is the in-session half of M01 and should be folded into the M01 item below.
5. **No user-visible state for any of the above.** When video has failed, the status panel stays GONE (`MA:1884-1886`). The only trace is `dec=0` in the optional stats overlay.

## Proposed work items

### P1 (H02 + SE4 client) — Add a client video-health state and gate input on it
- title: Gate input on decoder health; show a video-fault overlay; bounded decoder/session recovery
- owner: android-client-dev
- depends_on: []
- decision record: yes, a short one (`docs/decisions/00xx-video-health-input-gate.md`). Draft:
  > "Input capture is active only while the video is HEALTHY: a surface is attached, the current decoder generation has produced at least one output since its (re)start, and no terminal fault is set. A terminal fault is any of: give-up (RestartPolicy exhausted); no decoded output for 1500 ms while ≥ 3 non-config frames were queued to the codec (T-028 class); the decoder thread is not running ≥ 2 s after attach (M03 stuck). A static screen (no frames received) is never a fault. On a fault the client turns capture off (this sends the existing `RELEASE_ALL(USER)`, so there is no wire change), stops feeding and stops keyframe retries, shows an overlay, and recovers in this order: one codec restart after 1 s, one after 3 s, then a full session reconnect, then a manual 'Yeniden dene' button. A new session or config generation opens input only after its first decoded output."
- wire protocol: no change. `RELEASE_ALL.reason=USER` (0) is reused. PROTOCOL.md:44 already treats the reason as informational. An optional `VIDEO_FAULT=4` reason would be an orchestrator protocol change and is not required.
- files:
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt` (new, pure Kotlin)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt`
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`
  - `client-android/app/src/main/res/values/strings.xml` (overlay text)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/video/VideoHealthTest.kt` (new)
  - the card file
- Goal: Today a decoder that gives up, or silently produces no output, leaves a frozen or black image while pen and keys still reach the Mac. Make decoder health an explicit state that turns input off (with releases), is visible to the user, and recovers within a bounded number of steps.
- Out of scope:
  - generation tokens on delivery (P2);
  - teardown timeouts (P3);
  - host changes;
  - a new RELEASE_ALL reason;
  - latency metrics.
- Acceptance criteria:
  - [ ] (JVM) `VideoHealth` transitions: STARTING → HEALTHY on first output; HEALTHY → FAULT on give-up, on no-output-while-fed (1500 ms and ≥ 3 inputs), or on the decoder not running while attached; a static screen (no inputs) stays HEALTHY indefinitely; recovery steps are bounded and ordered; a new generation is STARTING until its first output.
  - [ ] (JVM) FAULT stops keyframe retries and the renderer stops feeding its queue (fake clock).
  - [ ] `syncInputActive` includes `videoHealth.inputAllowed`; entering FAULT calls `capture.setActive(false)`, which emits the existing release sequence + `RELEASE_ALL(USER)`.
  - [ ] Input does not open after an automatic reconnect or migration until the new generation's first decoded output (fixes Additional issue 2).
  - [ ] Overlay text is shown on FAULT with a "Yeniden dene" action, and no key characters are logged.
  - [ ] Log lines `ev=video_health state=… cause=…` (docs/LOGGING.md format).
  - [ ] Device (orchestrator, one at a time): a debug-only `--es decoder_fault create|configure|dequeue|silent` extra forces each fault. In each case: input stops within 1 frame of the fault, Mac shows no stuck key/pen while Shift is held + pen down during injection, the overlay is visible, and auto-recovery succeeds within ≤ 5 s when the fault is one-shot.
  - [ ] `./scripts/check.sh` passes.
- Plan hints:
  - Hook points are `VR:347-351` (give-up), `drainOutput` (`VR:540-548`, first output and last output time), `VR:472` (inputs queued), and `MA:643-649` (gate).
  - Keep `VideoHealth` UI-thread owned. Renderer callbacks post to it.
  - Have the 500 ms ticker (`MA:1365-1379`) evaluate the no-output timer, so no new thread is needed.
  - Risk: false positives on panels that throttle presentation. Base the timer on decoder *output* (`dequeueOutputBuffer`), not on `onFrameRendered`.

### P2 (M01 + T-028 ordering) — Generation-tagged video delivery with a barrier
- title: Drop video frames from non-current connections and from configs the renderer has not installed
- owner: android-client-dev
- depends_on: [] (can run in parallel with P1; touches SessionController plus a small part of MainActivity)
- decision record: no (implements the existing PROTOCOL §3 steps 5/7 intent).
- wire protocol: no change.
- files:
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt`
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/VideoDeliveryGate.kt` (new, pure)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt` (installed token)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (`onVideoFrame`, `installConfig`)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/session/VideoDeliveryGateTest.kt` (new)
  - the card file
- Goal: A frame must reach the decoder queue only if it came from the current video connection (`VideoConn.gen`) of the current control session, and only if its configId is the one the renderer has actually installed. After `abort()` returns, no frame from that connection may be delivered. This closes the cross-session hole (the host's configId always restarts at 1) and the T-028 in-session ordering race.
- Out of scope: host changes; changing when the client opens the video connection (keep it as is, gate on delivery instead).
- Acceptance criteria:
  - [ ] (JVM, deterministic, X4) A reader blocked at a barrier just before delivery, followed by `abort()` + a new gen/config activated, followed by releasing the reader, delivers zero frames. The same holds for a reader that still has buffered complete records after `abort()`.
  - [ ] (JVM) A frame whose configId ≠ the renderer-installed configId is dropped. Installing config K after frames of K were dropped results in exactly one STARTUP request (already sent by `reconfigure`) and no FRAMES_DROPPED storm.
  - [ ] (JVM) Same configId (1) in consecutive sessions: frames from session N's connection are dropped once session N+1 is current.
  - [ ] `currentConfigId` is reset to -1 on CloseVideo/CloseControl.
  - [ ] Device: 10× USB↔Wi-Fi migration plus 10× mode change while moving content. Each recovers on its first keyframe, with no `decode_error`, and `kf_req` per switch ≤ 2.
  - [ ] `./scripts/check.sh` passes.
- Plan hints:
  - `VideoDeliveryGate` holds `(videoGen, installedConfigId)` under a small lock. `VideoConn` calls `gate.deliver(gen, configId) { listener.onVideoFrame(msg) }` *inside* the lock, which is cheap because `offer` does not block. `abort()` closes the gate for that gen under the same lock, which gives the barrier.
  - `installConfig` sets `installedConfigId` *after* `r.reconfigure(config)` (`MA:1177`). Until then, frames of the new config are dropped instead of entering the old codec.
  - Mirror the audio pre-filter style (`SC:749`).
  - Risk: holding the lock across `onVideoFrame` must never block. `FrameQueue.offer` only takes its own short lock and the `vsyncIdle` post is non-blocking. Document this in the gate.

### P3 (M03) — Bounded, owned decoder teardown
- title: Bound the decoder generation hand-off; join the output thread; move per-codec state into the generation
- owner: android-client-dev
- depends_on: [P1] (P3 reports "stuck" through `VideoHealth`)
- decision record: no (implementation detail under P1's decision).
- wire protocol: no change.
- files:
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt`
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/RestartPolicy.kt`
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/CodecGeneration.kt` (new, optional pure helper)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/video/`
  - the card file
- Goal: A new codec generation never waits without limit for an old one, never shares mutable state with a straggler thread, and never piles up threads. If an old generation cannot be torn down within its budget, the renderer reports a terminal "stuck" fault (P1) instead of hanging silently.
- Out of scope: killing a native call (impossible); GL presenter teardown; host M02.
- Acceptance criteria:
  - [ ] `decodeLoop` waits for the previous generation for at most 2 s (`previous.join(2000)`). On timeout it logs `ev=decoder_previous_stuck`, reports FAULT(stuck) and does not open a codec. A later attach waits only for the newest stuck thread, so the chain does not grow (keep a single "last stuck" reference and refuse to start more than one waiting thread).
  - [ ] The generation is considered finished only when *both* the input and output threads have exited. `runCodec.finally` joins the output thread for up to 500 ms. If it is still alive, the generation records `outputStraggler` and the next generation's wait includes it.
  - [ ] `lastOutputNs`, `formatChanged`, the gauge, the pacer references and the PTS maps become per-`runCodec` locals or per-generation objects. A straggler can only touch its own copies, and shared `stats`/`counters` are updated only while its generation is current.
  - [ ] `decodeAttempts` waits with backoff between restarts (e.g. 100 ms, 500 ms, 1 s) instead of retrying immediately.
  - [ ] (JVM) Using a fake codec interface (or a pure `CodecGeneration` hand-off helper with injectable joins): a hung previous generation leads to a bounded wait, the FAULT callback, and no new codec; a straggler output thread does not change the next generation's gauge or `firstOutput`.
  - [ ] Device (X6, orchestrator): 100× background/foreground, 100× mode change and GL↔surface fallback. Thread count (`/proc/<pid>/task`), `dumpsys media.codec` instance count and RSS return to baseline ±5 %. Report `detach_slow`/`decoder_previous_stuck` counts.
  - [ ] `./scripts/check.sh` passes.
- Plan hints:
  - Code locations: `VR:263-272` (retire), `VR:328` (join), `VR:357-491` (runCodec), `VR:493-495` (shared fields).
  - Introduce a narrow `DecoderCodec` interface around the handful of MediaCodec calls used. This is needed for P1's JVM injection anyway; keep it inside `video/`.
  - Risk: the UI-thread `detachSurface` join (300 ms) must stay bounded because the surface is being destroyed.

### P4 (X3/X6 measurement) — Device fault-injection and churn soak run
- title: Run decoder fault injection and surface-churn soak on the tablet; record in NOTES
- owner: orchestrator (device tests one at a time)
- depends_on: [P1, P3]
- decision record: no. wire protocol: no.
- files: `docs/NOTES.md`, the card file.
- Goal: Produce device evidence that a terminal decoder fault releases input and recovers, and that surface churn returns resources to baseline.
- Acceptance criteria:
  - [ ] For each `decoder_fault` mode (P1 extra), 5 runs: time from fault to `input_active on=0`, host owed-release count = 0, time to the first image after recovery.
  - [ ] 100× fg/bg plus 100× mode change: threads/codecs/RSS start vs end.
  - [ ] Results dated in NOTES, including any run that was not performed ("not run").
- Plan hints: run `adb shell ls /proc/$(pidof dev.matebridge.client)/task | wc -l`, `adb shell dumpsys media.codec`, and `dumpsys meminfo dev.matebridge.client` before and after.

## Coverage
- H02: covered (CONFIRMED)
- M01: covered (CONFIRMED; practical rate low)
- M03: covered (CONFIRMED; framework mitigates the stop/release overlap, straggler output thread added)
- W1 (client half): covered (CONFIRMED, synchronous-mode nit)
- V6: covered (CONFIRMED)
- V7: covered (CONFIRMED)
- V8: covered (PARTIALLY CORRECT)
- V9: covered (CONFIRMED)
- V10: covered (CONFIRMED / already addressed by T-121, T-122)
- SE3: covered (CONFIRMED, video gap)
- SE4: covered (CONFIRMED)
- SE7 (M01/M03 parts): covered (CONFIRMED)
- X3: covered (gap confirmed)
- X4: covered (gap confirmed)
- X6: covered (NOT VERIFIABLE IN CODE)
- D3 (client parts): covered (CONFIRMED)
- F2 (video-health and decoder ownership parts): covered (CONFIRMED / PARTIALLY CORRECT)
- A1 (client half): covered (PARTIALLY CORRECT)
