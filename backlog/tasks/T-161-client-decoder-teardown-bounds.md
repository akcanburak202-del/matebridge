---
id: T-161
title: Bound the decoder hand-off, join the output thread, keep per-generation state
status: in_progress
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

- [ ] [JVM, first commit, red at HEAD] With the T-158 fake codec: (a) a previous generation that never exits makes the next attach wait forever (the test asserts a bounded wait and fails; it must not hang the suite, so it uses a timeout and releases its latch in `finally`); (b) a straggler output thread changes the next generation's gauge or `firstOutput`. Both are committed failing (or `@Ignore`d with the failing output quoted in the commit message) before the fix; Handoff names the commit.
- [ ] [JVM] A hung previous generation → wait ≤ 2 s, `ev=decoder_previous_stuck`, `fault(stuck)` reported via `onHealthEvent`, and no new codec created. Repeated attaches while stuck keep at most one waiting thread.
- [ ] [JVM] A generation is finished only when both input and output threads have exited; a straggler output thread is included in the next wait and cannot change the next generation's gauge, `firstOutput`, `lastOutputNs` or PTS maps.
- [ ] [JVM] `decodeAttempts` waits 100 ms / 500 ms / 1 s between restarts (fake clock); the 3-per-10 s give-up rule still holds. A `retire()` during a backoff wait wakes it at once, so `detachSurface` stays ≤ `JOIN_MS` during a backoff.
- [ ] `detachSurface` on the UI thread still blocks for at most `JOIN_MS` (300 ms).
- [ ] [device] Covered by T-164 (thread count, codec instances and RSS back to baseline after churn; `detach_slow` and `decoder_previous_stuck` counts reported).
- [ ] `./scripts/check.sh` geçiyor.

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

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
