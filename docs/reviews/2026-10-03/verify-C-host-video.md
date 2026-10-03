# Verification C — Mac host video pipeline (capture, encoder, send queue)

Verifier scope: M02, V1–V5, W1 (host half), LM1, LM4, PF4, PF6, PF7, X5, SE7 (M02 part), L03 (host compressed-buffer/crypto copies), A1 (host MediaOwner half), A2 (latest-frame pre-encode, HEVC-aware bounded queue, native capture/encode), W4 rows "Mac capture", "Mac encode" and "Mac socket".
HEAD = a30c769. All paths are relative to `/home/user/matebridge/host-mac/Sources/` unless stated otherwise. Line numbers are at HEAD.

### Thread / caller map for `HEVCEncoder` (basis for M02, X5, SE7, W4)

| Entry point | Thread / queue | Can reach `VTCompressionSessionEncodeFrame`? |
|---|---|---|
| `encode()` HEVCEncoder.swift:314 | SCK sample handler queue `matebridge.capture` (serial, userInteractive), ScreenCapture.swift:33,65 → VideoPipeline.swift:104-106 | yes (`offerLocked` → `perform` → `send`) |
| `resubmitLast()` via `requestKeyframe(resubmitNow: true)` HEVCEncoder.swift:307-310,346-369 | (a) StreamCoordinator event loop `Task` (StreamCoordinator.swift:157, `handleKeyframeRequest` VideoPipeline.swift:196-214, `prepareForNewConsumer` :228-234); (b) VideoSender `Task` on a refused frame (StreamCoordinator.swift:425-426 → VideoPipeline.swift:184-188) | yes, with `bypassGate: true` |
| `idleTick()` :474-480 | timer queue `matebridge.encoder.idle` (250 ms) | yes |
| `idleRefreshTick()` :457-472 | timer queue `matebridge.encoder.refresh` (off by default) | yes |
| `flushPending()` :649-656 | `DispatchQueue.global(qos: .userInteractive).asyncAfter` :643-647 (concurrent queue, never cancelled; `[weak self]`) | yes |
| `completed` → `releaseSlotAndDrain` :583-620 | VideoToolbox output-callback thread (VT calls back into VT from its own callback) | yes |
| `slotFailed` :600-610 | synchronously on whichever thread got an error from `EncodeFrame`, or the VT callback thread | yes (drains pending) |
| `requestKeyframe()` without resubmit | VT callback thread inside `frames.push` → `keyframeNeeded` → `EncoderBox.requestKeyframe` VideoPipeline.swift:319-323 | no (it only sets the flag) |
| `stop()` :659-679 | `VideoPipeline.teardown` VideoPipeline.swift:279-288, called from the coordinator loop (`destroyPipeline` StreamCoordinator.swift:713-717, `stopKeepingDisplay` :572), from the `fail()` Task VideoPipeline.swift:291-301 (independent of the coordinator loop), and from `deinit` :681 | calls `CompleteFrames` and `Invalidate` |

So at least six threads can call `send()`. The calls are **not** serialized in practice, and M02 is not moot.

## Verdicts

### M02 — Encoder slot reservation and the real VT call are not in the same order
- Verdict: **CONFIRMED** (mechanism exact). Impact is narrower than the review implies.
- Evidence:
  - `offerLocked` (HEVCEncoder.swift:495-516) and `takePendingLocked` (:624-634) check `!stopped`, copy `session` into `s` (:496, :625), and call `reserveSlot` (:536-548) while holding `lock`. That step bumps `inFlight`, makes the PTS strictly increasing (:542-543) and consumes `forceKeyframe` (:545-546). The `(Input, key, s)` tuple is then returned. The lock is released (:323, :367, :617, :653), and only then does `send()` call `VTCompressionSessionEncodeFrame(s, …)` (:565).
  - `stop()` (:659-679) sets `stopped` and nils `session` under the lock, then calls `CompleteFrames` and `Invalidate` outside it.
  - **Can EncodeFrame hit an invalidated session?** Yes. Thread A reserves and holds `s`, then releases the lock. Thread B runs all of `stop()`. Thread A then calls EncodeFrame on the invalidated `s`. `s` is a strong, ARC-retained CF reference, so this is not a use-after-free. VT is expected to return `kVTInvalidSessionErr` (−12903, not observed in NOTES). That leads to `slotFailed` → `forceKeyframe`, `consecutiveFailures += 1`, and `releaseSlotAndDrain`, which sees `stopped` and does nothing. `onFailure` trips only at 5 consecutive failures, and `VideoPipeline.fail` is a no-op once `state == .stopped` (VideoPipeline.swift:291-296). The visible effect is one `ev=encode_failed` log line at teardown.
  - **Submit-order inversion while streaming:** this is the more real effect. Reservation order (monotonic PTS, keyframe flag) is decided under the lock, but the VT call order is decided by thread scheduling after the lock is released. Both slots can be free (`maxInFlight = 2`, :50), so two submitters can race, for example capture plus coordinator `resubmitLast(bypassGate: true)`, or capture plus VT-callback drain or flush timer in decimation mode. VT can then receive PTS₂ before PTS₁. `FramePacer` documents "submitted capture timestamps never go backwards" (Core/Video/FrameGate.swift:46-48), and the encoder enforces that at reservation, not at the API boundary. Apple's EncodeFrame contract requires increasing PTS. The likely outcome is an encode error or no-output, then `slotFailed`, then a forced keyframe (an extra ~400 KB IDR at 2800×1840). The keyframe flag can also land on the later-submitted frame.
  - Same pattern for the T-087 QP cap: `updateQPBoost` sets `MaxAllowedFrameQP` under `boostLock` (:431-453, called :563), but EncodeFrame runs after `boostLock` is released. A concurrent capture submit can therefore be encoded under the refresh cap, or the reverse. The knob is off by default and ignored by the `fast` profile (NOTES:570).
  - Is everything serialized on one queue in practice? **No** (see the map above). Mitigations that exist: `cap.stop()` is awaited before `enc.stop()` (VideoPipeline.swift:281-282), the coordinator stops the sender before the pipeline (`destroyPipeline` → `stopConsumer` first), and every entry rechecks `stopped`. The window is therefore microseconds (unlock → VT call). It is reachable mainly through the `fail()` Task racing the coordinator, the idle and flush timers, or an SCK callback still in flight after `stopCapture`.
  - No cross-generation leakage: each encoder holds its own session and pushes into its own pipeline's `frames` (VideoPipeline.swift:92-97). `frames.finish()` (:284) makes later pushes no-ops (Core/Video/VideoFrameQueue.swift:24).
- Corrections:
  - The review cites "property update" as a racing call. The only mid-stream property call is the T-087 QP cap (default off). `setTargetFps` touches only the pacer.
  - There is no in-place "reconfigure". A settings change builds a new `VideoPipeline` and `HEVCEncoder` (StreamCoordinator.swift:572-573), so the reconfigure race reduces to the stop race.
  - The review misses the submit-order inversion during normal streaming and the re-entrant VT call from VT's own callback thread (`releaseSlotAndDrain` → `send`).
  - Not mentioned by the review, unverified: `send()` assumes VT never both returns an error *and* invokes the handler for the same frame (comment :606-607). If it ever does, `inFlight` is decremented twice and nothing bounds it at 0 (:614), which would silently raise the in-flight cap.
- Severity opinion: Medium is too high on current evidence. I rate it **Low–Medium**: no crash or corruption path (the session is retained), effects self-heal with one keyframe, and the window is tiny. Still worth a small fix because it breaks a stated invariant (monotonic submit) and is cheap to make deterministic.

### V1 — Capture: SCK minimumFrameInterval = 1/(fps·2), queueDepth = 5, only changed complete frames processed
- Verdict: **CONFIRMED**
- Evidence: ScreenCapture.swift:60 `minimumFrameInterval = CMTime(1, fps*2)`, with the rationale at :57-59 (SCK drops frames that arrive a hair early). :28 and :61 set `queueDepth = 5` (the comment says "> encoder in-flight limit + the retained last buffer"). :90 passes only `status == .complete` frames to the encoder; idle, blank and other statuses are only metered (:89). Pixel format 420f, sRGB colour space, 709 matrix at :54-56.
- Corrections: none. The doubled SCK rate is capped back to stream fps by `FrameGate`/`FramePacer` (Core/Video/FrameGate.swift), which the review does not mention.
- Severity opinion: descriptive, agree.

### V2 — Pre-encode: max 2 encodes in flight, 1 newest pending frame
- Verdict: **CONFIRMED**
- Evidence: `HEVCEncoder.maxInFlight = 2` (HEVCEncoder.swift:50). There is a single `pending` slot in `FramePacer` (Core/Video/FrameGate.swift:73) where newest wins (`offer` :134-179 replaces it and counts `overwritten`). `last` keeps a retained buffer for static-screen keyframes and resubmits (HEVCEncoder.swift:66, :504).
- Corrections: the review omits the send-rate gate (`FrameGate`, half-interval tolerance since T-072) and decimation to the panel rate (T-058). Both decide whether a frame is submitted, held or dropped.
- Severity opinion: descriptive, agree.

### V3 — Encode: VideoToolbox, hardware acceleration *requested*, B-frame reordering off
- Verdict: **CONFIRMED**
- Evidence: HEVCEncoder.swift:138 uses `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true`, which is "Enable", not "Require". :160 sets `AllowFrameReordering=false`. :159 sets `RealTime=false` with the default `.fast` profile (:133-137). The LLRC spec key is set only for the `llrc` profile (:139). Main AutoLevel profile at :232.
- Corrections: none.
- Severity opinion: agree. See PF7 for the startup check.

### V4 — Post-encode: ~2-frame bounded queue; keyframe/resync rules
- Verdict: **CONFIRMED**
- Evidence: Core/Video/BoundedFrameQueue.swift:9 has `defaultCapacity = 2`, and CODEC_CONFIG counts toward the capacity. On overflow it drops the oldest unprotected delta, purges dependants up to the next keyframe, then sets `keyframeNeeded` and `awaitingKeyframe` (:41-64). `startNewConsumer`/`resync` restrict the queue to `[config]` and refuse deltas until a keyframe arrives (:81-94). The thread-safe wrapper is in VideoFrameQueue.swift. Keyframe requests are coalesced through `KeyframeGate` (VideoPipeline.swift; T-122).
- Corrections: the live type is `VideoFrameQueue` wrapping `BoundedFrameQueue` (C06 names only the policy struct). VideoSender pulls only when `transport.canSend` (VideoSender.swift:90-95), so the backlog stays in this queue rather than in the socket.
- Severity opinion: descriptive, agree. This is a good design to keep (A2).

### V5 — Network write: one app record in flight; writable / TCP not-sent threshold
- Verdict: **CONFIRMED** for the default path (with a nuance).
- Evidence: the default video socket is `bsd` (Core/Session/TransportKnobs.swift:79-95, flipped in T-092). `SocketVideoGate.maxRecordsInFlight = 1` (Core/Video/SocketVideoTransport.swift:11). `canSend` requires `inFlight < 1` and `isWritableForNewRecord` (outbound buffer empty and `poll(POLLOUT)` under `TCP_NOTSENT_LOWAT`, default 128 KiB: TransportKnobs.swift:100-112, Core/Session/BsdTcpSocket.swift:372-382). The gate is rechecked inside `sendFrame` under the lock before sealing, so no record counter is burned (SocketVideoTransport.swift:67-80).
- Corrections: the `nw` fallback (`MATEBRIDGE_VIDEO_SOCKET=nw`) allows **2** in flight with no low-water check (MateBridgeHost/Session/SessionServer.swift:18, :59-67).
- Severity opinion: descriptive, agree.

### W1 (host half) — CGVirtualDisplay → SCK → NV12 → VT HEVC → Annex-B record, encrypted, dedicated video TCP
- Verdict: **CONFIRMED**
- Evidence:
  - The pipeline goes `VirtualDisplay` (`obtainDisplay`, VideoPipeline.swift:134-143) → `ScreenCapture` 420f full range (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` = NV12 full range, ScreenCapture.swift:54) → `HEVCEncoder` → AVCC-to-Annex-B conversion in `handle` (HEVCEncoder.swift:683-716) → `VideoFrameQueue` → `VideoSender` → `VideoLink`/`SocketVideoTransport` → `Message.videoFrame(...).sealed(using:)` with per-connection AES-GCM (Core/Crypto/Records.swift:38-63) → BSD socket on the separate video connection.
  - H.264 is selectable via `MATEBRIDGE_CODEC=h264` (T-086).
- Corrections: none (only the H.264 option goes unmentioned).
- Severity opinion: descriptive.

### W4 rows — "Mac capture", "Mac encode", "Mac socket"
- Verdict: **PARTIALLY CORRECT**
- Evidence:
  - *Capture:* a dedicated serial userInteractive queue `matebridge.capture` (ScreenCapture.swift:33,65). Correct.
  - *Encode:* "locked state + capture/timer/VT callback calls; in-flight limit good; call and stop order = M02 risk" is correct but incomplete. Submits also come from the global-queue flush timer (HEVCEncoder.swift:643-647), the StreamCoordinator event-loop Task (keyframe and new-consumer resubmits), the VideoSender Task (refused-frame keyframe), and the optional refresh timer. See the map above.
  - *Socket:* "read-owner queue + separate write queue (size limits, close-once)" is mostly right. Reads run on the owner queue (the session queue: SessionServer.swift:615 `video.start(queue: queue)`). However, the **first write attempt runs synchronously on the caller's thread** (the VideoSender Task on the Swift cooperative pool) inside `write` under the connection lock (BsdTcpSocket.swift:392-415, `drainLocked` :522-527). Only the remainder and completions use the private `dev.matebridge.socket.write` queue (:294, :536-570). Close-once is confirmed (`fdClosed` plus a `pendingCancelHandlers` countdown at :469-500, :585-592). Size limits: `maxPendingRecords`/`maxPendingBytes` defaults; for video, the effective bound is the 1-record gate.
- Corrections: as above. Also, `HEVCEncoder.stop()` runs `VTCompressionSessionCompleteFrames` synchronously inside the async `teardown` (VideoPipeline.swift:282), which blocks a cooperative-pool thread for up to about two encode times. This is minor.
- Severity opinion: agree that the encode row carries the risk (M02); the other two rows are fine.

### LM1 — Encode time = submit → VT callback only
- Verdict: **CONFIRMED**
- Evidence: `send()` stamps `start` (HEVCEncoder.swift:552) and `trace.submittedUs` (:564) just before EncodeFrame, and the callback stamps `elapsedUs` and `encodedUs` (:570-572). It therefore includes queueing inside VT behind the other in-flight frame. It excludes slot or gate wait (`slot_wait`, `gate_wait`, separate stages since T-072) and the Annex-B conversion (`conv` = `enqueuedUs − encodedUs`, Core/Video/LatencyTrace.swift:52). The T-113 card documents this definition (backlog/tasks/T-113-host-encode-time-gap.md:49,70).
- Corrections: the host already reports the full per-stage breakdown: `sck_lag`, `hold`, `gate_wait`, `slot_wait`, `enc`, `conv`, `queue`, `write`, `cap_to_sent` (T-070/T-072). "Encode time" is one stage of that set, not the only host number.
- Severity opinion: informational, agree.

### LM4 — Host trace origin ≠ wire `capture_time_us`
- Verdict: **CONFIRMED**, with one wrong detail. **ALREADY KNOWN** (NOTES 2026-10-01 ~12:40, line 401; T-072 open question, backlog/tasks/T-072-host-latency-metric-and-hold.md:50). There is no card for it.
- Evidence: `trace.captureUs = FrameTrace.origin(display, pts, delivered)` = min of the three (HEVCEncoder.swift:560-561; Core/Video/LatencyTrace.swift:64-69). The wire carries `captureTimeUs` = SCK PTS (HEVCEncoder.swift:553 → `EncodedVideoFrame.captureTimeUs` :713). Resubmits are stamped `now + lead` to stay consistent with PTS (:361-364, `ResubmitStamp` in Core/Video/EncoderKnobs.swift:300).
- Corrections: the wire stamp is **not "older"**. The SCK PTS and `displayTime` lie about 6.6 ms **after** the callback (NOTES:401, `pts_vs_deliv = +6.6 ms`), so the host origin is normally the callback time. The tablet's `latency_us` therefore **under-reports** by about 6.6 ms; it does not over-report. Pacing is unaffected (constant offset). Audio uses the same clock for A/V sync (docs/PROTOCOL.md:507), so changing the wire semantics is not free.
- Severity opinion: Low (reporting only). It needs a decision, not code (see the proposed item LM4-D).

### PF4 — "Right base, but not zero-copy" (host part)
- Verdict: **CONFIRMED**
- Evidence: the SCK IOSurface-backed 420f buffer goes straight into VT. `retagForSession` changes only attachments (HEVCEncoder.swift:252-265; T-113 removed VT's own colour conversion, −2.7 ms). The only pixel copy is the optional idle-refresh `copyForRefresh` (:373-419, off by default). Compressed-side copies are under L03.
- Corrections: none on the host side.
- Severity opinion: agree (informational).

### L03 (host part) — Compressed-buffer and crypto record copies
- Verdict: **PARTIALLY CORRECT.** The copies exist, but the host already measures the whole stage, and it is small.
- Evidence (per frame, `bsd` path):
  1. `CMBlockBuffer` → `[UInt8]` (HEVCEncoder.swift:710-711).
  2. `AnnexB.convert` into a new array (:712; Core/Video/AnnexB.swift:5-20).
  3. `encodePayload` writer for the VIDEO_FRAME payload (Core/Message.swift:107, :156).
  4. `plain` Data = type + payload (Core/Crypto/Records.swift:43-45).
  5. GCM ciphertext (inherent).
  6. Output assembly `out` (:51-55).

  The `nw` fallback adds `Data(bytes)` (SessionServer.swift:137). That is 4 avoidable full copies plus 1 inherent.

  Existing stage metrics cover them: `conv` (copies 1–2) and `write` (copies 3–6 plus seal plus syscall). NOTES:401 and :405 show `cap_to_sent` p50 7.2 ms vs `enc` p50 6.9 ms, so everything after encode costs about 0.3 ms p50 (p99 about 8.3 ms vs about 8 ms).
- Corrections: the review asks to "measure with an allocation profiler and stage times". Host stage times already exist and show low cost. The only open question is the keyframe p99 (about 432 KB), which the existing `ev=latency` split by `isKeyframe` could answer.
- Severity opinion: Low. Agree with "measure before optimising".

### PF6 — NV12 4:2:0 SDR limits small coloured text; tags OK; verify with ramps
- Verdict: **CONFIRMED** (as an assessment). Host tagging is consistent; the visual check has not been done.
- Evidence: capture is 420f full range, `colorSpaceName = sRGB`, `colorMatrix = 709` (ScreenCapture.swift:54-56). The session sets primaries 709, transfer **sRGB** (IEC 61966-2-1) and matrix 709 (HEVCEncoder.swift:190-194, :242-244). Input buffers are retagged to the same values (:252-265, T-113). STREAM_CONFIG sends H.273 primaries=1, transfer=13, matrix=1, full_range=1 (Core/Video/VideoSettings.swift:45, :95-107). T-113 verified that the bitstream VUI matches (primaries=1, transfer=13, matrix=1). The client sets `KEY_COLOR_RANGE`, `KEY_COLOR_STANDARD` and `KEY_COLOR_TRANSFER` from STREAM_CONFIG (client VideoRenderer.kt:286-288).
- Corrections: none, but the review does not note that the HEVC profile is Main (8-bit 4:2:0 only) and that the Sharpness bench measures luma only (SharpnessBench.swift:17), so chroma loss is unmeasured. T-113 left "colour/brightness comparison with the Mac" untested (T-113 Handoff). No existing card for X11.
- Severity opinion: Low. Agree that this is a measurement item, not a code change.

### PF7 — Keep RealTime=false; verify at startup that the hardware encoder was really selected
- Verdict: **PARTIALLY CORRECT / PARTIALLY ADDRESSED**
- Evidence: `RealTime=false` with the `.fast` default at every fps (HEVCEncoder.swift:130-137, :159; T-047/T-053). The hardware encoder is only *requested* (:138). `cadenceReadback()` already reads `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` (:287). It is logged at **every pipeline start** inside `ev=cadence_setup … encoder_read[… Hardware=…]` (VideoPipeline.swift:165-170 → StreamCoordinator.swift:595-596), and `--encode-bench` checks it too (MateBridgeHost/Video/EncodeBench.swift:165). Nothing *acts* on it: there is no warning level, no menu summary and no counter. A software fallback would only be visible to someone reading the cadence line.
- Corrections: the review says there is no verification. The host does read the value back; it just buries it. (The decoder half is client-side and out of my scope.)
- Severity opinion: Low. Promote it to a dedicated warning line and a smoke-package field; do not switch to `Require` (see the item PF7-H).

### X5 — Encoder shutdown race test: barrier between reserve and send, stop/reconfigure → no submit after invalidate, deterministic
- Verdict: **CONFIRMED as a gap.** No such test exists.
- Evidence: `HEVCEncoder` lives in the `MateBridgeHost` target, and the only test target is `MateBridgeCoreTests` (host-mac/Package.swift:18). The VT calls have no seam, so no deterministic test is possible today. `FramePacer` (Core) is tested (FrameGateTests.swift), but only the pure decision logic, not the lock → VT ordering.
- Corrections: "reconfigure" is the same as stop plus a new instance (see M02).
- Severity opinion: agree it belongs in the acceptance matrix. It is cheap once the ordering logic moves into Core behind a fake backend.

### SE7 (M02 part) — Encoder submit vs invalidate ownership gap
- Verdict: **CONFIRMED** (same as M02).
- Evidence and corrections: see M02.
- Severity opinion: Low–Medium (see M02).

### A1 (host MediaOwner half) — Capture, encoder and video transport as a rebuildable media generation
- Verdict: **PARTIALLY CORRECT.** The structure largely exists already.
- Evidence:
  - `StreamCoordinator` is already a single-owner event loop: a bounded, ordered mailbox handled one event at a time (StreamCoordinator.swift:7-11, :157-160, :260). It owns `pipeline` and `consumer` (sender or drain).
  - `VideoPipeline` is the rebuildable media generation: display + capture + encoder + `frames`, one `start()` per instance, idempotent `stop()` (class doc, VideoPipeline.swift:19-28).
  - `VideoSender` is per video connection.
  - Gaps: (1) the virtual display is owned *inside* `VideoPipeline` and handed over via `stopKeepingDisplay` (DisplayOwner and MediaOwner are conflated; `DisplayLease` 10 s grace), and (2) the encoder has no single submission owner (M02).
- Corrections: on the host, MediaOwner is a narrow refactor (move display ownership up into the coordinator or a DisplayOwner; serialise encoder submits), not a new layer. Display lifetime belongs to another verifier's DisplayOwner/F2 items.
- Severity opinion: agree it is a direction. On the host it is lower priority than the review suggests, because the coordinator already provides ordered ownership.

### A2 (assigned bullets) — Keep latest-frame pre-encode, HEVC-aware bounded post-encode queue, native capture/encode
- Verdict: **CONFIRMED** (all three exist and are tested where pure).
- Evidence: latest-frame pre-encode is `FramePacer` (Core/Video/FrameGate.swift:46-206) plus `maxInFlight=2`. The dependency-aware queue is `BoundedFrameQueue` (purges dependants, keyframe gate, resync), tested in KeyframeResyncTests and VideoTests. Native capture and encode are SCK plus VT, with no third-party dependencies (decision 0002).
- Corrections: none.
- Severity opinion: agree. Keep them.

## Additional issues found

1. **Submit-order inversion at the VT boundary** (HEVCEncoder.swift:510/629 reserve vs :565 call). This is more likely than the shutdown race (it can happen in steady state) and is covered in M02 above. It is fixed by the same change.
2. **Possibly non-contiguous `CMBlockBuffer` read as contiguous** (HEVCEncoder.swift:705-711). `CMBlockBufferGetDataPointer(..., lengthAtOffsetOut: nil, totalLengthOut: &length, ...)` then reads `length` bytes from `base`. The pointer is only valid for `lengthAtOffset` bytes. If VT ever returns a multi-segment block buffer, this over-reads. VT output is normally contiguous, so this is not observed. The fix is cheap (compare `lengthAtOffset == totalLength`, else `CMBlockBufferCopyDataBytes`) and pairs with the L03 copy reduction. Low.
3. **`inFlight` has no floor and no per-reservation token** (HEVCEncoder.swift:600-620). Correctness relies on VT never both returning an error and calling the handler for one frame. That is unverified on macOS 27. A double release would silently allow 3+ frames in flight. Low; add `precondition`/clamp plus a log line.
4. **The T-087 QP cap is applied outside the submit ordering** (HEVCEncoder.swift:431-453 vs :565). Under concurrency the cap can apply to the wrong frame. The knob is off by default and ineffective on `fast`. Low; fixed by the same serialisation.
5. **Synchronous `VTCompressionSessionCompleteFrames` on a Swift cooperative thread** (VideoPipeline.swift:282 → HEVCEncoder.swift:676). It blocks for up to about 2 encode times during teardown. Minor; disappears if teardown runs on the encoder's owner queue.
6. **Re-entrant VT calls from VT's own output-callback thread** (`releaseSlotAndDrain` → `send`, HEVCEncoder.swift:612-620). This works today, but if EncodeFrame ever blocks for capacity, it blocks VT's callback delivery. Moving submits to an owner queue removes this.

## Proposed work items

### Item M02-H — Serialise encoder submits and teardown on one owner queue (also covers X5, SE7, additional 1/3/4/6)
- title: Serialize HEVCEncoder submits, QP updates and teardown on one encoder queue
- owner: mac-host-dev
- depends_on: []
- decision record: not required. It is an internal concurrency change with no dependency, protocol or default behaviour change. Recommend recording the "single submit owner" invariant in the card's Handoff and in the encoder's class doc.
- wire protocol: **no change**.
- files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift (new: pure ordering/lifecycle logic plus backend protocol)
  - host-mac/Tests/MateBridgeCoreTests/Video/EncoderSubmitOrderTests.swift (new)
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift (only if teardown must await the owner queue)
- Goal: every `VTCompressionSessionEncodeFrame`, mid-stream `VTSessionSetProperty`, `CompleteFrames` and `Invalidate` call for one encoder runs on one serial owner queue, in exactly the order the slots were reserved. After `stop()` is called, no submit reaches VT. This restores the "monotonic PTS at the API boundary" invariant and makes the shutdown race deterministic and testable.
- Out of scope: changing `maxInFlight`, pacer and gate policy, encoder profiles or knobs; the client decoder (M03); display ownership (A1/F2).
- Acceptance criteria:
  - [ ] (XCTest, Core) With a fake backend that records calls and can block inside `encode`, a barrier between reserve and submit plus a concurrent `stop()` produces zero `encode` calls after `invalidate`. Deterministic: barrier-driven, no sleeps.
  - [ ] (XCTest) A stress run of 10 000 iterations with concurrent capture offers, `bypassGate` resubmits, flush-timer takes, slot releases and `stop()` gives a backend PTS sequence that is strictly increasing, exactly one release per reservation, and `inFlight` never < 0 or > `maxInFlight`.
  - [ ] (XCTest) A deliberately broken variant (submit after unlock on the caller thread) makes the first test fail (mutation check, recorded in Handoff).
  - [ ] `inFlight` release is idempotent per reservation (token), and a double release is logged at `warning` instead of corrupting the count.
  - [ ] (Real Mac + tablet) 10 min at 120 fps with 20 STREAM_PREFS changes and 10 video reconnects gives `ev=encode_failed` = 0. `ev=latency enc` and `cap_to_sent` p50 are within ±0.3 ms of the baseline and p99 has not grown.
  - [ ] `./scripts/check.sh` passes.
- Plan hints:
  - Extract the lock-protected decision (reserve, take pending, stopped) plus an ordered submit queue into a Core type that is generic over `protocol CompressionBackend { func encode(_ f: Frame, key: Bool) -> Int32; func setQP(...); func completeAndInvalidate() }`. `HEVCEncoder` adapts VT to it.
  - Simplest correct shape: under `lock`, after `reserveSlot`, call `submitQueue.async { send(...) }`. Enqueueing under the lock makes FIFO order equal reservation order. `stop()`: under `lock` set `stopped`, then `submitQueue.async { CompleteFrames; Invalidate }` (or `sync` if teardown must wait). Everything enqueued before it runs on a live session, and nothing can be enqueued after it.
  - VT callbacks must only take the lock and enqueue. Never `submitQueue.sync` from a callback or from `deinit`: a block on `submitQueue` may drop the last reference, so detect "already on queue" with `DispatchQueue.setSpecific`.
  - Move `updateQPBoost` into the same submit block.
  - Risks: one extra thread hop per frame (tens of µs; measure). EncodeFrame blocking now delays only later submits, which is the same throughput as today with `maxInFlight=2`. Keep `encode()` non-blocking for the SCK queue.
  - Also fix the `CMBlockBuffer` contiguity check here or in L03-H (whichever lands first).

### Item PF7-H — Make a software-encoder fallback visible
- title: Warn when VideoToolbox did not select the hardware encoder
- owner: mac-host-dev
- depends_on: []
- decision record: not required (diagnostics only). Recommend **not** switching to `RequireHardwareAcceleratedVideoEncoder`. NOTES (2026-09 T-046 entry, line 272) shows the media engine being shared with a bench; Require would turn transient contention into a failed pipeline. Warning plus measurement is safer.
- wire protocol: no change.
- files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - docs/LOGGING.md (event list; orchestrator approval if LOGGING is orchestrator-owned)
- Goal: after session creation, read `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` once. Log `ev=encoder_hw using_hw=1` at info, or `using_hw=0|unknown` at **warning**, and surface "software encoder" in the menu summary. Today the value is only buried inside `ev=cadence_setup`.
- Out of scope: client decoder-name check (separate android item); changing the encoder specification.
- Acceptance criteria:
  - [ ] (XCTest, Core) Pure mapping of a property read result (true/false/unreadable status) to log level and fields.
  - [ ] (Real Mac) A normal start logs `ev=encoder_hw using_hw=1` exactly once per pipeline.
  - [ ] (Real Mac, optional) Forcing a software path (e.g. an unsupported size via the bench) logs a warning.
  - [ ] `./scripts/check.sh` passes.
- Plan hints: reuse the `read(_:)` helper in `cadenceReadback` (HEVCEncoder.swift:274-288). Expose `usingHardware: Bool?` and log it from `createPipeline` next to `cadence_setup` (StreamCoordinator.swift:595-596).

### Item LM4-D — Decide what `capture_time_us` means for latency reporting
- title: Record the capture-timestamp semantics and the client latency offset
- owner: orchestrator
- depends_on: []
- decision record: **yes**. Draft: "`VIDEO_FRAME.capture_time_us` stays the ScreenCaptureKit presentation timestamp on the host time clock (and resubmits keep `now + lead`, `ResubmitStamp`). The tablet pacer and A/V sync (PROTOCOL.md §6, AUDIO capture_time_us) depend on it, and switching to callback time would shift every lateness threshold by ~6.6 ms. Consequently the tablet's `latency_us` excludes the SCK lead (`pts_vs_deliv`, ~+6.6 ms measured 2026-10-01). End-to-end budgets are computed as host `cap_to_sent` (callback origin) + network + client decode/present, and reports that use the client figure alone must say it under-reports by `pts_vs_deliv`. Revisit only if an optical input-to-photon measurement (LM3) shows a different offset."
- wire protocol: no byte change. Text-only clarification in docs/PROTOCOL.md §4/§6 (`capture_time_us` = SCK PTS, may lead the callback).
- files: docs/decisions/00xx-capture-timestamp-semantics.md, docs/PROTOCOL.md (text), docs/LOGGING.md (note on `latency_us`).
- Goal: close the T-072 open question so latency numbers from host and tablet are not compared as if they shared an origin.
- Out of scope: changing the stamp; client pacer changes.
- Acceptance criteria: [ ] decision merged; [ ] PROTOCOL/LOGGING text updated; [ ] fixture check unaffected (`python3 protocol/fixtures/gen.py --check`).
- Plan hints: cite NOTES:401 and T-072:50. Optionally have the host log `pts_vs_deliv` p50 in the 1 s stats line it already emits, so offline analysis can add it.

### Item L03-H — Trim compressed-frame copies on the host send path (measure-gated, low priority)
- title: Remove redundant compressed-frame copies between VT output and the sealed record
- owner: mac-host-dev
- depends_on: [M02-H] (it touches `handle()` in the same file; sequence to avoid conflicts)
- decision record: no. wire protocol: **no change**. Bytes on the wire must be identical, and the golden fixtures must still pass.
- files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/AnnexB.swift
  - host-mac/Sources/MateBridgeCore/Crypto/Records.swift
  - host-mac/Sources/MateBridgeCore/Message.swift
  - matching tests under host-mac/Tests/MateBridgeCoreTests/{Video,Crypto}/
- Goal: first, confirm with existing `ev=latency` `conv` and `write` stages split by keyframe vs delta that copies matter (expected: well under 1 ms even for about 432 KB IDRs). Only if they do: copy the block buffer once (`CMBlockBufferCopyDataBytes`, which also fixes the non-contiguous read), convert AVCC→Annex-B **in place** when `lengthSize == 4` (start code and length prefix are both 4 bytes), and build `type || payload` once into the seal input.
- Out of scope: removing or weakening encryption or bounds checks; client-side copies; the `nw` path.
- Acceptance criteria:
  - [ ] (XCTest) In-place Annex-B conversion equals `AnnexB.convert` output for 1/2/4-byte length sizes and for malformed inputs, which are still rejected.
  - [ ] (XCTest) Sealed records are byte-identical to the current implementation for fixture inputs (crypto vectors pass).
  - [ ] (XCTest) A multi-segment `CMBlockBuffer` (built in a test) is read correctly. If the test needs CoreMedia in Core, put the helper in Core behind a closure.
  - [ ] (Real Mac) Report `conv` and `write` p50/p99 before and after for keyframes. If the "before" keyframe `conv+write` p99 is < 0.5 ms, close the card after the contiguity fix only.
  - [ ] `./scripts/check.sh` passes.
- Plan hints: HEVCEncoder.swift:705-715; AnnexB.swift:5-20; Records.swift:38-56 (`plain` Data, `out` assembly); Message.swift:107,156. Keep `RecordSealer` the only owner of the counter.

### Item PF6-M — Colour and chroma fidelity check (measurement only)
- title: Measure chroma and range fidelity of the stream with test patterns
- owner: user (procedure by the orchestrator)
- depends_on: []
- decision record: no (result goes to NOTES; a profile change such as HEVC 4:2:2/4:4:4 would need a later decision). wire protocol: no change.
- files: docs/NOTES.md (append, dated).
- Goal: verify that the sRGB/709/full-range tags yield correct levels and acceptable small coloured text, before anyone considers chroma upgrades.
- Procedure:
  1. On the Mac virtual display, open a static page with: 1 px and 2 px red, blue and green text on white and black; 0–255 grey ramp; patches at 0/16/235/255; saturated colour bars.
  2. Capture the tablet screen (`adb exec-out screencap -p`) and a Mac screenshot of the virtual display.
  3. Compare the black and white patch values (full vs limited range crush), the ramp (gamma; T-113 predicted "slightly darker = correct") and coloured-text edge bleed at the default bitrate and at the maximum bitrate.
  4. Record the host build SHA, mode, bitrate, and the tablet `codec_format` log line with range, standard and transfer.
- Acceptance criteria: [ ] NOTES entry with the numbers above; [ ] explicit verdict that range is correct (0→0, 255→255 ±2) or not; [ ] a follow-up card only if a defect is found.

## Coverage

| Claim ID | Verdict entry |
|---|---|
| M02 (all sub-points: reserve/encode/flush/drain/stop/invalidate threads; EncodeFrame on invalidated session; session captured under lock and nil'd at stop; serialization in practice) | yes (M02 + thread map) |
| V1 | yes |
| V2 | yes |
| V3 | yes |
| V4 | yes |
| V5 | yes |
| W1 (host half) | yes |
| LM1 | yes |
| LM4 | yes |
| PF4 | yes |
| PF6 (colour tags/matrix) | yes |
| PF7 (UsingHardwareAcceleratedVideoEncoder check) | yes |
| X5 | yes |
| SE7 (M02 part) | yes |
| L03 (host compressed-buffer/crypto copy part) | yes |
| A1 (host MediaOwner half) | yes |
| A2 (latest-frame pre-encode, HEVC-aware bounded queue, native capture/encode) | yes |
| W4 rows "Mac capture", "Mac encode", "Mac socket" | yes |
