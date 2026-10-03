---
id: T-176
title: Stop forced-IDR feedback on host-side queue drops
status: review
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

(a) keeps older frames over newer ones, which contradicts the AGENTS.md hard rule "for video frames the newest frame wins, and stale frames are dropped". Choose (a) only with an explicit argument in Handoff (for example: the refused deltas are undecodable anyway). The orchestrator must approve that deviation in review. **Default: (b).**

Either way, one invariant must hold: **the queue is never left in `awaitingKeyframe` with no keyframe pending and no force scheduled.** Otherwise video freezes until the 300 s safety-net keyframe (`KeyframeIntervalPolicy`, T-075) or a client DECODE_ERROR. Document the chosen policy and this argument in the code comment and in Handoff.

**Optional (b) from F A-2, pre-encode skip:** skip submitting new captures while the sink queue has been full (sender blocked) for more than one frame interval, so that newest-frame-wins happens *before* encode. Queue occupancy is available from `VideoFrameQueue`, which avoids touching `VideoSender`/`SocketVideoTransport` (not in `files:`). If the skip needs a signal from those files, stop and write it under *Açık sorular*. The skip decision is made in `VideoPipeline` before `encode()`; `EncoderSubmitOrder.swift` (T-162) is not changed. The `HEVCEncoder.swift` change is limited to the hook that keeps `last` current (below). If the hook needs a change to `EncoderSubmitOrder.swift`, stop and write it under *Açık sorular*.

**Static-screen risk (pre-encode skip):** SCK delivers no captures while the screen is static (`SharpnessBench.swift:15` comment). If the last capture before the content settles is skipped, "the first capture after the queue drains" never comes. `HEVCEncoder`'s `last` then still holds an older buffer, and `resubmitLast`/`idleTick` re-encode stale content. So a skipped capture must still replace the encoder's `last` buffer, or be submitted once the queue drains.

**Ordering and serialization:**
- This card can land before T-127's measurements, because it fixes a reasoned loop. Its own device criterion is an A/B against the previous build, so it does not need a T-127 baseline.
- Serialize with T-170 (same file: `HEVCEncoder.swift`). The hot-file chain is T-162 → T-170 → T-176 → T-177 → T-204 → T-187.
- T-162 (dependency) owns the encoder submit queue. Any encode-skip hook must respect T-162's owner queue and must not submit around it. The skip decision itself lives in `VideoPipeline` (see above).

**Review:** Codex (`./scripts/codex-review.sh main task/T-176-host-drop-idr-feedback`), for the keyframe/reference-chain logic.

Wire: none. No PROTOCOL.md change.

## Kapsam dışı

- Client keyframe logic; protocol messages.
- Congestion control, bitrate changes, pacing (T-177, T-195, T-196).
- Changing `VideoSender`'s refused-frame rate limit.

## Kabul kriterleri

- [x] [XCTest] `[IDR, d1] + d2`: the drop does not produce an immediate `keyframeNeeded` force while a keyframe is queued ahead, pending, or written within `windowUs`. The test checks that the frames popped afterwards form a decodable sequence: no delta whose reference was dropped is ever popped.
- [x] [XCTest] Host-side forces (`internalForce`) are coalesced within `windowUs`. A coalesced force is re-issued once the window or `pendingTimeoutUs` expires if the queue still awaits a keyframe. Fake-clock test: nothing is swallowed forever, and `awaitingKeyframe` never outlives `pendingTimeoutUs` without a force.
- [x] [XCTest] The existing `KeyframeRequestCoalescerTests`, `KeyframeResyncTests` and `VideoTests` (BoundedFrameQueue) pass unchanged, or every changed expectation is justified in Handoff.
- [ ] (n/a: not built, see Open questions 1) [XCTest] (only if the optional pre-encode skip is built) While the sink queue stays full for more than one frame interval, captures are not submitted. The first capture after the queue drains is submitted. A forced keyframe is never skipped. A skipped capture still replaces the encoder's `last` buffer (or is submitted once the queue drains), so a screen that goes static during back-pressure converges to the latest content. Test: push N captures while the queue is full, then stop capturing and drain; the last submitted buffer is capture N.
- [x] [doc] The chosen policy and the reference-chain argument are written in the `BoundedFrameQueue` comment and in Handoff.
- [ ] [device] A/B in one session on topology 3 (or 2), T-127 workload: the build before T-176 vs this branch, same workload, ≥ 3 runs each. `idr=`/`idr_bytes_max=` per stats window (`net ev=stats`) are lower, client `frames_dropped` and decode errors do not rise, and no freeze is longer than 1 s. If T-127 has already run without T-176, compare against its topology-3 row instead.
- [ ] [doc] The orchestrator's Codex review findings are answered in Handoff.
- [x] `./scripts/check.sh` geçiyor.

## Plan

Politika: **(b)** (varsayılan). Kuyruğun düşürme seçimi aynı kalır (en eski delta + bağımlıları), yalnızca zorlanan keyframe hız sınırlanır.

1. `BoundedFrameQueue`: `isAwaitingKeyframe` ve `hasQueuedKeyframe` okuyucuları; düşürme kararı değişmez. Yorumda politika ve referans zinciri argümanı (kuyruktaki IDR zinciri onarmaz; d1 düşünce d2 ve sonrası çözülemez, bu yüzden yeni keyframe yine gerekir, ama hemen değil).
2. `VideoFrameQueue`: kilit altında tek anlık görüntü `keyframeState` (`awaitingKeyframe`, `keyframeQueued`, `keyframesPushed`). Geri çağırma imzası aynı kalır (mevcut testler değişmez).
3. `KeyframeRequestCoalescer`: `hostDrop(nowUs:queue:)` ve `checkDeferred(nowUs:queue:)` → `HostDecision { forceKeyframe, recheckAtUs }`.
   - Kuyruk keyframe beklemiyorsa: hiçbir şey.
   - Zorla, eğer: yolda keyframe yok (encoder içinde bekleyen yok, gönderilmiş-ama-yazılmamış yok, kuyrukta yok) ve son yazım `windowUs`'den eski; ya da erteleme `pendingTimeoutUs`'i aştı (sert sınır).
   - Aksi halde ertele ve `recheckAtUs` döndür (yazım + `windowUs`, yolda keyframe için kısa yoklama, sert sınır).
   - Zorladıktan sonra da kuyruk keyframe beklediği sürece izleme sürer (`pendingTimeoutUs` sonra tekrar zorla): kuyruk asla keyframe bekler halde, yolda keyframe ve planlı zorlama olmadan kalmaz.
   - `reset` ertelemeyi temizler; `internalForce` (reddedilen kare yolu) ve istemci zorlamaları ertelemenin saatini yeniler.
4. `VideoPipeline` (`EncoderBox`): kuyruk geri çağırması → `hostDrop`; `recheckAtUs` için tek seferlik `asyncAfter` zamanlayıcı → `checkDeferred`; zorlamada `encoder.requestKeyframe()` (sonraki yakalama IDR; durağan ekranda encoder'ın 1 s boşta keyframe'i). Reddedilen kare yolu (`requestKeyframe()`) değişmez (kapsam dışı, VideoSender 500 ms ile sınırlı).
5. Testler (`Tests/MateBridgeCoreTests/Video/HostDropKeyframeTests.swift`): `[IDR,d1]+d2` anında zorlamaz + çıkan kareler çözülebilir (referans zinciri modeli); sahte saatle erteleme/sert sınır/hiçbir şey yutulmaz; mevcut testler değişmeden geçer.
6. İsteğe bağlı encode-öncesi atlama: **yapılmıyor** (EncoderSubmitOrder'a `last` güncelleme kancası ya da kuyruk boşalma sinyali gerektirir; risk/kapsam). Handoff'ta not.

Riskler: erteleme sırasında video donar (en çok yazım + 250 ms, sert sınır 1 s); kuyruk anlık görüntüsü ile yazım tamamlanması arasındaki yarış yalnızca fazladan keyframe üretebilir, eksik değil.

## Handoff

- **Commit:** `05205e3` (implementation; plan `73014b9`; this Handoff is in the commit after them).
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift`: `isAwaitingKeyframe`, `hasQueuedKeyframe` and the policy/reference-chain comment. The drop decision is unchanged.
  - `host-mac/Sources/MateBridgeCore/Video/VideoFrameQueue.swift`: `keyframeState` (a single-lock snapshot) and the `KeyframeQueueState` type. The callback signature is unchanged.
  - `host-mac/Sources/MateBridgeCore/Video/KeyframeRequestCoalescer.swift`: `hostDrop`, `checkDeferred`, `HostDecision`, `pollUs` (50 ms), `hostForcedTotal`/`hostDeferredTotal`. `request`/`internalForce` restart the hard-bound clock; `reset` ends the watch.
  - `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`: `EncoderBox.queueDropped` → `hostDrop`, plus a one-shot `asyncAfter` re-check (`recheckAtUs`) → `checkDeferred`.
  - `host-mac/Tests/MateBridgeCoreTests/Video/HostDropKeyframeTests.swift` (new, 11 tests).
  - `HEVCEncoder.swift` was **not** touched (the optional skip was not built).
- **Policy: (b).** The queue keeps "newest frame wins": it drops the oldest delta and purges its dependents. With `[IDR, d1] + d2`, `d1` is dropped, `d2` is purged and `IDR` stays. The queued IDR does not repair the chain, because every delta after `d2` references `d1`. So deltas are refused until a new keyframe (`awaitingKeyframe`), and what is popped stays decodable (`IDR`, then the next keyframe). Only the **timing** of the force changed. `hostDrop` forces at once only when no keyframe is on its way and none was written within `windowUs`. "On its way" means one of:
  - still inside the encoder (pending, `keyframesPushed` unchanged);
  - pushed but not yet written (pending, count changed);
  - queued (`keyframeQueued`);
  - seen in the queue earlier and not yet written (`keyframeAheadSinceUs`).

  Otherwise the force is deferred until `lastWritten + windowUs`, and a keyframe on its way is re-checked every 50 ms. Invariant: the deferral is at most `pendingTimeoutUs` (1 s) from the drop or the last force (hard bound). Even after a force, the watch continues while the queue awaits a keyframe, and if that keyframe does not arrive the force is repeated every 1 s. So the queue is never left awaiting a keyframe with no keyframe on its way and no force scheduled. An isolated drop (nothing on its way, last IDR old) still forces at once, as before.
- **Varsayımlar:**
  - Immediate force on a drop: `requestKeyframe(resubmitNow: false)` (a capture just produced a frame, so the next capture becomes the IDR, as before). Force from the timer: `resubmitNow: true` (the screen may have gone static, so the last buffer is re-encoded immediately, as for client requests).
  - The refused-frame path (`VideoPipeline.requestKeyframe()` → `internalForce`, `resubmitNow: true`) is **unchanged**. It is not a queue drop: the frame was already popped, the queue does not await a keyframe, and later deltas go out. Deferring it would leave the client showing artefacts. VideoSender already rate-limits it to 500 ms (changing that is out of scope).
  - The queue snapshot is read under the gate lock (lock order gate → queue; the queue never calls out while holding its lock). One race remains: a keyframe the sender has popped whose write has not completed is visible to the coalescer only through `pending`/the marker. An untracked keyframe (periodic, failed-slot re-arm) can therefore cause one extra force. This can only produce an extra IDR, never a missing one.
  - **Changed expectations in existing tests: none.** `KeyframeRequestCoalescerTests`, `KeyframeResyncTests`, `BoundedFrameQueueTests`/`NewConsumerTests` (`VideoTests.swift`) and `VideoFrameQueueKeyframeCountTests` pass unchanged. `testKeyframeCallbackFiresOnDeltaDrop` is still valid: the callback still means "a keyframe is needed", and the force decision moved to the pipeline.
  - Simulation (`testBackPressureBurstForcesFewerKeyframesAndRecovers`, 60 fps, 400 KB IDR, a link that needs ~170 ms per IDR): with the old policy the link is ~100% busy with IDRs (5 s: 148 forces, 31 IDRs written). With the new policy: 11 forces, 13 IDRs, link busy ~40%. After the burst, deltas flow again.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - [device] A/B (topology 3 or 2, T-127 workload, ≥3 runs each): per `net ev=stats`, are `idr=` / `idr_bytes_max=` lower, do client `frames_dropped`/decode errors not rise, and is there no freeze > 1 s? **Not run.**
  - Static screen: if the screen goes static right after a drop, the force from the timer re-encodes the last buffer immediately (`resubmitNow: true`). Verify there is no freeze on the device.
  - Codex review: not run yet (to be done by the orchestrator: `./scripts/codex-review.sh main task/T-176-host-drop-idr-feedback`). Findings are to be answered here.
- **Açık sorular:**
  1. **Optional pre-encode skip was not built, and policy (b) alone does not fully break the loop.** If an IDR blocks the sender for longer than ~2 frame intervals (60 fps: 400 KB at < ~100 Mbps effective; 120 fps: < ~190 Mbps), the 2-frame queue overflows on that IDR alone. Every IDR then produces its own drop. With (b) the link sits idle for ≥ `windowUs` between IDRs, so contention can clear and the loop breaks on its own in practice. On a link that stays slow, however, the stream remains IDR-only at ≤ 1/(W+250 ms) (previously 1/W, with the link saturated). The real breaker is newest-frame-wins *before* encode. The card's threshold ("queue full for > 1 frame interval") is not enough for this: the frame already inside the encoder still overflows. The gate needs `queue count + encoder in-flight/pending >= capacity`. That needs a `HEVCEncoder` read of in-flight/pending count (a change outside the `last` hook) and a "queue drained" signal from `VideoFrameQueue` (pop) for the held capture. I suggest a follow-up card (in the T-177 chain).
  2. **Logging (LOGGING.md not in `files:`).** For A/B readability, add `host_kf_forced=<n> host_kf_deferred=<n>` to the `net ev=stats` line (`hostForcedTotal`/`hostDeferredTotal` are ready; the field goes in `StreamCoordinator` + `docs/LOGGING.md`). For now the A/B relies on the existing `idr=`/`idr_bytes_max=` fields.
