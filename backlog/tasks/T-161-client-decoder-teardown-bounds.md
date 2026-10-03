---
id: T-161
title: Bound the decoder hand-off, join the output thread, keep per-generation state
status: review
phase: 6
owner: android-client-dev
depends_on: [T-159, T-160]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/RestartPolicy.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/CodecGeneration.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-161-client-decoder-teardown-bounds.md
---

## Amaç

A new decoder generation waits for the previous decoder thread with no timeout, never waits for the previous output thread, and shares renderer-wide mutable state with it. If an old thread hangs inside a native `stop()`/`release()`/`createCodec`, every later attach parks behind it, threads pile up, and nothing is visible; a straggler output thread can also corrupt the next generation's counters. After this card the hand-off is bounded, a stuck generation is reported as a video fault (decision 0019, via T-159's `VideoHealth`), and each generation owns its own state.

Source: external architecture review 2026-10-03 (M03, SE7, X6, D3); verification: docs/reviews/2026-10-03/verify-B-client-video.md (P3, additional issue 3).

Decision 0019 must be accepted by the user before work starts.

## Bağlam

- **R-tagged finding (M03).** Per review p11 the work starts with deterministic failing tests committed red before the fix (first acceptance item). They use the T-158 `DecoderCodec` fake.
- **Evidence (HEAD a30c769; `VR` = `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt`):**
  - `VR:263-272` `retire(wait)`: sets `active=false`, `current=null`, `lingering=thread`; it joins `JOIN_MS=300` only for `detachSurface` (UI thread) and logs `detach_slow` on timeout. `attachSurface`/`reconfigure` pass `wait=false`.
  - `VR:328` `try { att.previous?.join() }`: the next generation waits with no timeout and no log. A hung old thread makes every later attachment park behind it (one more thread per surface churn or config change). Meanwhile `attached=true`, frames are queued with no consumer, input is live and keyframe requests continue (the H02 side effect, now gated by T-159).
  - `VR:482-489` `runCodec.finally`: `outRunning=false` → `outThread.join(500)` → `codec.stop()` → `codec.release()`, called whether or not the output thread has exited.
  - The next generation joins only the previous *decoder* thread, never the previous *output* thread. A straggler output thread keeps mutating renderer-wide state: `formatChanged` and `lastOutputNs` are plain non-volatile fields (`VR:493-495`); `gauge` is reset by the new generation (`VR:384`) and then decremented by the old thread; `stats`, `counters`, `firstOutput` (the old thread can consume the new generation's bypass); `readyByPts`/`captureByPts`.
  - `decodeAttempts` (`VR:341-355`) restarts immediately. If a stuck codec still holds the hardware decoder instance, `createCodec` can fail 4 times within milliseconds and give up: the M03 → H02 link.
  - Framework mitigation (keep in mind, do not rely on it): the output thread's blocking wait is ≤ 20 ms, and calls after `stop/release` throw `IllegalStateException`, which `VR:425-426` swallows. Vendor HAL behaviour is unknown; nothing was reproduced on the device (T-013 open question 3).
- **Plan hints:**
  - `previous.join(2000)`; on timeout log `ev=decoder_previous_stuck`, report `fault(stuck)` through the renderer's `onHealthEvent` callback (T-159 adds the generic `VideoHealth.fault(cause)` input and its `MainActivity` wiring, so this card needs neither `VideoHealth.kt` nor `MainActivity.kt`) and do not open a codec. Keep a single "last stuck" reference and refuse to start more than one waiting thread, so the chain cannot grow.
  - A generation counts as finished only when both its input and output threads have exited. If the 500 ms output join times out, record `outputStraggler`; the next wait includes it.
  - Move `lastOutputNs`, `formatChanged`, the gauge, pacer references and the PTS maps into a per-generation object (`CodecGeneration.kt`, optional pure helper with injectable joins). Shared `stats`/`counters` are updated only while the generation is current.
  - `decodeAttempts` backoff between restarts: 100 ms, 500 ms, 1 s (in `RestartPolicy` or beside it). It runs on the decoder thread, so a plain `Thread.sleep(1000)` would make `detachSurface`'s 300 ms join time out (`detach_slow`): the backoff wait is woken by `retire()` (`att.active=false`), e.g. by parking on the attachment.
  - The UI-thread `detachSurface` join (300 ms) must stay bounded: the surface is being destroyed.
  - LOGGING.md is not in `files:`; list `decoder_previous_stuck` and any other new line under *Açık sorular*.
- **Serialize with:** `VideoRenderer.kt` chain T-158 → T-159 → T-160 → T-161 → T-168 → T-183 → T-184 (T-159 and T-160 are depends_on).
- No wire change; `docs/PROTOCOL.md` is not affected. Device acceptance (X6 churn) runs in T-164.

## Kapsam dışı

- Killing a native call (impossible).
- GL presenter teardown (`GlPresenter.kt`); the GL path is removed later by T-184.
- Host encoder ordering (T-162).
- The `VideoHealth` state machine itself and its `fault(cause)` wiring (T-159); this card only reports the stuck fault into it through `onHealthEvent`.

## Kabul kriterleri

- [x] [JVM, first commit, red at HEAD] With the T-158 fake codec: (a) a previous generation that never exits makes the next attach wait forever (the test asserts a bounded wait and fails; it must not hang the suite, so it uses a timeout and releases its latch in `finally`); (b) a straggler output thread changes the next generation's gauge or `firstOutput`. Both are committed failing (or `@Ignore`d with the failing output quoted in the commit message) before the fix; Handoff names the commit.
- [x] [JVM] A hung previous generation → wait ≤ 2 s, `ev=decoder_previous_stuck`, `fault(stuck)` reported via `onHealthEvent`, and no new codec created. Repeated attaches while stuck keep at most one waiting thread.
- [x] [JVM] A generation is finished only when both input and output threads have exited; a straggler output thread is included in the next wait and cannot change the next generation's gauge, `firstOutput`, `lastOutputNs` or PTS maps.
- [x] [JVM] `decodeAttempts` waits 100 ms / 500 ms / 1 s between restarts (fake clock); the 3-per-10 s give-up rule still holds. A `retire()` during a backoff wait wakes it at once, so `detachSurface` stays ≤ `JOIN_MS` during a backoff.
- [x] `detachSurface` on the UI thread still blocks for at most `JOIN_MS` (300 ms).
- [ ] [device] Covered by T-164 (thread count, codec instances and RSS back to baseline after churn; `detach_slow` and `decoder_previous_stuck` counts reported).
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Kırmızı commit** (`test/.../video/DecoderTeardownTest.kt`, T-158 fake): (a) eski kuşak `stop()` içinde asılı →
   yeni kuşak ≤ 2 s içinde `Fault(stuck)` bildirmeli (HEAD: sınırsız `join()`, olay gelmez; kapı `finally`'de açılır);
   (b) `dequeueOutputBuffer` içinde kalan çıktı iş parçacığı (500 ms join'i aşan straggler) yeni kuşağın
   `firstOutput` atlamasını tüketmemeli ve yeni kuşak codec'i straggler çıkmadan açmamalı. İkisi `@Ignore` ile, HEAD'deki
   başarısız çıktı commit mesajında.
2. **`CodecGeneration.kt` (yeni, saf):**
   - `CodecGeneration` (kuşak: gen, surface, thread, `active`, canlı iş parçacığı sayısı, `outputStraggler`).
   - `GenerationHandoff` (renderer başına bir tane, kendi kilidi): `threadStarted/threadExited/retire`;
     `acquire(gen, 2000)` → `Ready | Retired | Stuck(prev)`. Tek "owner" referansı (codec tutabilecek son kuşak); bir
     kuşak ancak owner'ın hem girdi hem çıktı iş parçacıkları çıktıysa owner olur. `retire()` bekleyeni hemen uyandırır,
     emekliye ayrılan bekleyen codec açmadan çıkar → zincir büyümez, bekleyen en çok bir. `pause(gen, ms)`: geri çekilme
     beklemesi, `retire()` ile uyanır. Saat/bekleme `HandoffTimer` ile enjekte edilir (testte sahte saat).
   - `CodecState` (codec örneği başına): `lastOutputNs`, gauge, PTS haritaları, `ArrivalTracker`, pacer referansları,
     `running`; `current = running && generation.active`. `formatChanged` yerel değişken olur.
3. **`RestartPolicy.kt`:** 3/10 s kuralı aynen; `delayMs` = pencere içindeki yeniden başlatma sırasına göre 100 / 500 /
   1000 ms.
4. **`VideoRenderer.kt`:** `lingering`/`previous.join()` yerine `handoff.acquire`; `Stuck` → `ev=decoder_previous_stuck`,
   besleme durur, `onHealthEvent(Fault(stuck))`, codec açılmaz. Çıktı iş parçacığı kuşağın canlı sayısına girer; 500 ms
   join aşılırsa `outputStraggler` + `ev=output_straggler`. Paylaşılan `stats`/`counters`/`firstOutput`/`progress`
   yalnızca `CodecState.current` iken güncellenir (straggler tamponu muhasebesiz geri verir). `live: CodecState?`
   (UI'nin okuduğu gauge/pacer) yalnızca kendi kaydı ise temizlenir. `decodeAttempts` yeniden başlatmadan önce
   `handoff.pause(delay)`; `detachSurface` `JOIN_MS` sınırını korur.
5. Testler: kırmızı testlerin `@Ignore`'u kaldırılır; tekrar eden attach'te tek bekleyen, geri çekilme gecikmeleri (sahte
   saat), geri çekilme sırasında `detachSurface` ≤ `JOIN_MS`, `GenerationHandoff`/`RestartPolicy` saf testleri.

Riskler: `not_running` (2 s) ile `stuck` (2 s) yarışır; ikisi de FAULT (hangisinin önce yazıldığı fark etmez). Geri
çekilme sırasında kuyruk dolarsa FRAMES_DROPPED istekleri hold-off ile sınırlı kalır.

## Handoff

- **Commit:** `ac952c6` (Codex --high review P2 fixes, after merging `main` in `abc66da`, no conflicts) on top of
  `ae8c260` (fix), branch `task/T-161-client-decoder-teardown-bounds`. Red step: `e57f689` (both tests
  `@Ignore`d, HEAD failure output quoted in the commit message: (a) `no stuck fault within 3 s (waited 3005 ms):
  [Generation(gen=1), Running(gen=1), Generation(gen=2)]`; (b) `codec 2 created while generation 1's output thread was
  alive`, and in an earlier variant `the straggler consumed generation 2's first-output bypass`). Plan: `1cc9d25`.
- **Review düzeltmeleri (`ac952c6`):**
  - P2-1: a `decode_error` restart inside a generation first waits (`GenerationHandoff.awaitOwnThreads`, bounded by
    `previousWaitMs`) for the previous codec's output thread. On timeout it logs `decoder_previous_stuck` with
    `prev_vgen` = `vgen` and `out_straggler=1`, reports `Fault(stuck)` and creates no codec, so at most one straggler
    exists at a time; it keeps the generation unfinished, so the next generation's hand-off waits for it.
  - P2-2: `feedGen`/`feedBlocked` change only under `feedLock`. A decoder thread blocks feeding and publishes
    `give_up`/`stuck` (`onGiveUp`, `Fault`) atomically and only while its generation is still the fed one
    (`blockFeedingIfCurrent`), so a stale report can neither re-open nor block the current generation.
  - P2-3: each output's shared bookkeeping (decode progress + `FirstOutput`, stats, first-output bypass, pacing, trace)
    runs under the generation's `sharedLock` together with the "still current?" check (`CodecState.ifCurrent`). Retire
    (`GenerationHandoff.retire`) and the codec's end (`CodecState.stop`) take the same lock, so an output that passed the
    check finishes before the retire returns, and none starts after it. Codec calls stay outside the lock, and the sink's
    stats and `onFrameRendered` stats use the same guard. Presentation counters (`SlotReleaser`, late drops) belong to
    the codec (`CodecState.counters`), and `logPresent` reads the live codec's.
  - New tests in `DecoderTeardownTest` (each fails against `ae8c260`): in-generation straggler → stuck, one codec; stale
    stuck report held in its log line while gen 3 starts and faults → feeding stays blocked, no `Fault(2)`; the same with
    a healthy gen 3 → feeding stays on; output held *inside* the post-check section (FirstOutput callback) → a retire
    from another thread waits for it (not done after 300 ms), and the bypass armed after the retire stays armed.
    `GenerationHandoffTest`: `awaitOwnThreads`. All rerun 6× green; `./scripts/check.sh`: ALL OK.
- **Dokunulan dosyalar:**
  - `video/CodecGeneration.kt` (new, pure): `CodecGeneration` (gen, surface, thread, `active`, live-thread count,
    `outputStraggler`), `HandoffTimer` (clock + bounded `Condition` wait; tests fake it), `GenerationHandoff`
    (`acquire` → `Ready | Retired | Stuck(previous, waitedMs)`, `retire`, `pause`, `threadStarted/threadExited`),
    `CodecState` (per codec instance: gauge, PTS maps, `ArrivalTracker`, pacers, `lastOutputNs`, `running`, `current`),
    `PtsMap` (the former `BoundedMap`).
  - `video/RestartPolicy.kt`: `delayMs()` 100 / 500 / 1000 ms by position in the window; `allow` unchanged.
  - `video/VideoRenderer.kt`: `previous.join()` / `lingering` replaced by `handoff.acquire(att, PREVIOUS_WAIT_MS=2000)`;
    `Stuck` → `ev=decoder_previous_stuck`, feeding stopped, `onHealthEvent(Fault(gen, STUCK))`, no codec. Output
    thread counted in the generation; 500 ms join timeout → `outputStraggler` + `ev=output_straggler`. Renderer-wide
    `gauge`, `adaptive`, `cpdActive`, PTS maps, `arrival`, `formatChanged`, `lastOutputNs` removed: per-codec
    `CodecState` (`formatChanged` is now a local); `live` (read by `logPresent`/`paceDUs`/overflow line) cleared only by
    its own run. `stats`/`counters`/`firstOutput`/`progress`/`onFrameRendered` stats are touched only while the codec
    is current; a straggler hands its buffers back without bookkeeping. `decodeAttempts` backs off via
    `handoff.pause` (woken by `retire()`). New constructor params with defaults (`handoffTimer`, `previousWaitMs`,
    `restartDelaysMs`) for tests; `MainActivity` / `VideoTestActivity` unchanged.
  - Tests: `DecoderTeardownTest.kt` (new, 5 renderer tests), `GenerationHandoffTest.kt` (new, 5 pure tests),
    `DecoderLifecycleTest.kt` (one stale comment).
- **Testler:** (a) hung `stop()` → `Fault(2, STUCK)` ≤ 2 s + margin, `waited_ms` in [2000, 3000], one codec, gen 2
  never `Running`, not fed. (b) straggler output thread: no `create#2` until it left `dequeueOutputBuffer`, bypass still
  armed, its frame counted nowhere (`decoded=0`, no `FirstOutput`), gen 2's own first output then takes the bypass.
  5 attaches while stuck: gens 2–5 exit without a codec or fault, exactly one waiting thread, only gen 6 reports
  `stuck`; after the hung codec finishes, `restartCodec()` opens codec 2. Fake clock: waits `[100, 500, 1000]`,
  `decode_error` stamps 1000/1100/1600/2600, then `give_up`. Detach during a 60 s backoff: returns < `JOIN_MS`, no
  `detach_slow`, no restart. Teardown/handoff/lifecycle/health tests rerun 6× green; `./scripts/check.sh`: ALL OK.
- **Varsayımlar:**
  - (review) A retire on the UI thread may now wait for one output's bookkeeping in progress (pure Kotlin, no codec
    call, µs). In production the `FirstOutput` callback inside it only posts to the UI thread.
  - (review) `ev=present` slot/late-drop counters cover the window since the running codec started: a codec restart
    within a 10 s window drops the earlier codec's counts (as the gauge p95 already did).
  - "Generation finished" = every thread it started exited (decoder thread + each codec's output thread). Within one
    generation a `decode_error` restart does not wait for a straggler of the previous codec (backoff covers it); its
    `CodecState` is separate, so the straggler cannot touch the new codec's state.
  - A generation that timed out (`Stuck`) or was retired while waiting never becomes the owner; the owner (last
    generation that may hold a codec) is the single "last stuck" reference, so the next generation (e.g. the
    decision-0019 restart step) waits for the hung one again, one waiter at a time.
  - Backoff order: pause first, then `queue.reset(DECODE_ERROR)` + request right before the new codec (as before), so
    the host's keyframe answers the codec that will decode it. During a 1 s pause the queue may overflow; its
    FRAMES_DROPPED requests stay under the existing 500 ms hold-off.
  - Late `onFrameRendered` callbacks of a stopped codec and the gauge p95 window across a codec restart are dropped.
- **Test edilmeyenler / cihazda doğrulanacaklar (T-164; nothing ran on the tablet):**
  1. Normal USB connect: image appears, `MB/decoder ev=codec_start` then `video_health state=healthy`; no
     `decoder_previous_stuck`, no `output_straggler`.
  2. 20× mode change (Netlik ↔ Akıcı ↔ Oyun 60) and 10× background/foreground while content moves: image back each
     time, one `codec_stop` + `codec_start` pair per change, no `detach_slow`, no `decoder_previous_stuck`; thread count
     (`adb shell ps -T -p <pid> | grep -c mb-decoder`) and RSS back to baseline afterwards.
  3. `--es decoder_fault dequeue --ei decoder_fault_after_s 10`: `decode_error` lines spaced ~100 ms / 500 ms / 1 s
     apart (log timestamps), then `give_up` and `video_health state=fault cause=give_up`; recovery as in T-159.
  4. Count `detach_slow`, `decoder_previous_stuck`, `output_straggler` over the whole run (expected 0 on a healthy
     HAL; any non-zero is the M03 evidence T-164 asks for).
- **Açık sorular:**
  - `docs/LOGGING.md` (orchestrator; all `MB/decoder`):
    `ev=decoder_previous_stuck vgen=N prev_vgen=N waited_ms=N out_straggler=0|1` (W; `prev_vgen` = `vgen` when the
    previous codec of the same generation left a stuck output thread): a new generation (or codec restart) waited
    `PREVIOUS_WAIT_MS` (2 s) for the previous one and opens no codec (video FAULT `stuck`);
    `ev=output_straggler vgen=N join_ms=500` (W): a stopping codec's output thread did not exit within 500 ms; the next
    generation waits for it.
  - The T-159 `not_running` rule (2 s after the generation began) and the 2 s stuck bound fire at about the same time;
    `VideoHealth` may record `cause=not_running` instead of `stuck` for a hung hand-off. Both are FAULT; if T-164 needs
    the exact cause, raise `NOT_RUNNING_MS` slightly or let `stuck` overwrite `not_running` (T-159 territory).
