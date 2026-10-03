---
id: T-176
title: Stop forced-IDR feedback on host-side queue drops
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-162]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoFrameQueue.swift
  - host-mac/Sources/MateBridgeCore/Video/KeyframeRequestCoalescer.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-176-host-drop-idr-feedback.md
---

## Amaç

Under Wi-Fi back-pressure the host drops a delta frame from its 2-frame queue and then forces a new IDR every time, with no rate limit. That IDR (hundreds of KB) lands on a link that is already congested, which causes more drops and more IDRs: a positive-feedback loop. After this card, host-side queue drops no longer cause IDR storms, and the stream stays decodable. Wi-Fi bursts then stop starving audio and control.

Source: external architecture review 2026-10-03 (H03); verification: docs/reviews/2026-10-03/verify-F-network.md (F-4, additional issues A-1, A-2).

## Bağlam

**Evidence at HEAD (a30c769):**
- `BoundedFrameQueue.push` (`host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift:40-64`) handles overflow like this:
  - it drops the oldest non-protected frame;
  - it purges later deltas up to the next keyframe, scanning **forward only** from the dropped index;
  - if no keyframe follows, it sets `keyframeNeeded` and `awaitingKeyframe`.
- `VideoFrameQueue.push` (`VideoFrameQueue.swift:22-36`) then calls `keyframeNeeded()` outside the lock.
- The pipeline wires that callback to `EncoderBox.requestKeyframe` (`host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:74`, `:318-323`). It calls `internalForce` and `encoder.requestKeyframe()` **unconditionally**: the next captured frame becomes an IDR.
- A second unconditional host force is the sender's refused-frame path: `VideoPipeline.requestKeyframe()` at `VideoPipeline.swift:182-188` uses `resubmitNow: true`, reached from `StreamCoordinator.swift:426`. `VideoSender` rate-limits only that refused-frame path, to once per 500 ms (`host-mac/Sources/MateBridgeCore/Video/VideoSender.swift:42`, `:117-121`, `:140ff`). The F report cites VideoSender lines 218-283; that file has 157 lines at HEAD.
- `KeyframeRequestCoalescer.internalForce` (`KeyframeRequestCoalescer.swift:106-110`) only records the pending state. It never suppresses anything. Only client `KEYFRAME_REQUEST`s are coalesced (T-122).
- The encoder keeps encoding at full fps while the socket gate is closed (F A-2). Frames are encoded and then thrown away in the 2-frame queue, and that is what triggers the drops.
- The encoder entry point is `HEVCEncoder.requestKeyframe(resubmitNow:)` (`host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:307-310`).
- Device precedent: NOTES 2026-10-02 ~11:00/11:35 shows IDR storms filled the link and starved audio. T-122 fixed only the client-request side.

**Reference-chain argument (read before choosing a policy):** the F report says the scenario `[IDR, d1] + d2` requests another IDR "even though an IDR is still queued at the head". That queued IDR does not repair the stream. Dropping `d1` breaks `d2` and every later delta the encoder produces, because they reference `d1` through `d2`. Some new keyframe is still needed eventually. The real fault is the immediate, unconditional force. Workable policies:
- **(a) Drop newest instead:** when a keyframe sits ahead in the queue, keep `IDR, d1`, refuse `d2` and later deltas until the next keyframe, and coalesce the request.
- **(b) Keep today's drop choice:** coalesce the force through `KeyframeRequestCoalescer` (pending, or written within `windowUs`), with a deferred force when the window expires.

Either way, one invariant must hold: **the queue is never left in `awaitingKeyframe` with no keyframe pending and no force scheduled.** Otherwise video freezes until the 300 s safety-net keyframe (`KeyframeIntervalPolicy`, T-075) or a client DECODE_ERROR. Document the chosen policy and this argument in the code comment and in Handoff.

**Optional (b) from F A-2, pre-encode skip:** skip submitting new captures while the sink queue has been full (sender blocked) for more than one frame interval, so that newest-frame-wins happens *before* encode. Queue occupancy is available from `VideoFrameQueue`, which avoids touching `VideoSender`/`SocketVideoTransport` (not in `files:`). If the skip needs a signal from those files, stop and write it under *Açık sorular*. The `HEVCEncoder.swift` change is limited to that encode-skip hook.

**Ordering and serialization:**
- This card can land before T-127's measurements, because it fixes a reasoned loop. T-127's `idr=` data then verifies it.
- Serialize with T-170 (same file: `HEVCEncoder.swift`). The hot-file chain is T-162 → T-170 → T-176 → T-177 → T-186 → T-187.
- T-162 (dependency) owns the encoder submit queue. Any encode-skip hook must go through T-162's owner queue, not around it.

**Review:** Codex (`./scripts/codex-review.sh main task/T-176-host-drop-idr-feedback`), for the keyframe/reference-chain logic.

Wire: none. No PROTOCOL.md change.

## Kapsam dışı

- Client keyframe logic; protocol messages.
- Congestion control, bitrate changes, pacing (T-177, T-195, T-196).
- Changing `VideoSender`'s refused-frame rate limit.

## Kabul kriterleri

- [ ] [XCTest] `[IDR, d1] + d2`: the drop does not produce an immediate `keyframeNeeded` force while a keyframe is queued ahead, pending, or written within `windowUs`. The test checks that the frames popped afterwards form a decodable sequence: no delta whose reference was dropped is ever popped.
- [ ] [XCTest] Host-side forces (`internalForce`) are coalesced within `windowUs`. A coalesced force is re-issued once the window or `pendingTimeoutUs` expires if the queue still awaits a keyframe. Fake-clock test: nothing is swallowed forever, and `awaitingKeyframe` never outlives `pendingTimeoutUs` without a force.
- [ ] [XCTest] The existing `KeyframeRequestCoalescerTests`, `KeyframeResyncTests` and `VideoTests` (BoundedFrameQueue) pass unchanged, or every changed expectation is justified in Handoff.
- [ ] [XCTest] (only if the optional pre-encode skip is built) While the sink queue stays full for more than one frame interval, captures are not submitted. The first capture after the queue drains is submitted. A forced keyframe is never skipped.
- [ ] [doc] The chosen policy and the reference-chain argument are written in the `BoundedFrameQueue` comment and in Handoff.
- [ ] [device] Wi-Fi, full-screen bursts (T-127 topology 3 workload): host `idr=` per second (`net ev=stats`) is below the T-127 baseline. Client `frames_dropped` and decode errors do not rise. No video freeze longer than 1 s.
- [ ] [doc] The orchestrator's Codex review findings are answered in Handoff.
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
