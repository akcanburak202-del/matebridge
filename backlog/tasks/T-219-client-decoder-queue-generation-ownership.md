---
id: T-219
title: Decoder input queue: a retired generation must not consume the next generation's frames
status: review
phase: 6
owner: android-client-dev
depends_on: [T-161]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/CodecGeneration.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-219-client-decoder-queue-generation-ownership.md
---

## Amaç

gpt-6-astra değerlendirmesi (P1 #2): yeniden yapılandırma eski kuşağı emekliye ayırır, ortak kuyruğu sıfırlar, yenisini başlatır ve yeni config için teslimi açar. Ama eski giriş döngüsü `att.active`'i yalnız `prefetch`/`awaitNext`'e girmeden önce denetliyor; dönen kareyi tüketip göndermeden önce yeniden denetlemiyor. Araya girme: eski decoder bekliyorken yeniden yapılandırma kuyruğu sıfırlayıp yeni kareleri kabul eder; eski bekleyici uyanır, yeni CODEC_CONFIG ya da keyframe'i alır ve emekliye ayrılan codec'e gönderir. Yeni kuşak codec sahipliğini doğru bekler ama başlangıç karesi olmadan başlar (yeniden keyframe isteği, gecikme ya da siyah).

## Bağlam

- Kanıt: `VideoRenderer.kt` ~:289, ~:538; `FrameQueue.kt` ~:189; `CodecGeneration.kt` ~:100.
- Statik eşzamanlılık bulgusu, cihazda görülmedi. Kuyruk tüketimi codec sahipliğinin yanında **kuşak sahipliği** de istiyor: kuyruk her kareyi bir kuşak kimliğiyle verir ve yalnız o kuşağın tüketicisine teslim eder; emekliye ayrılan tüketici uyanınca boş döner. Dequeue'dan sonra `active` denetleyip kareyi atmak yetmez (yeni kuşağın karesini kaybettirir).
- T-161 kuralları: kilit altında dışarı çağrı yok; emekliye ayırma sınırlı.

## Kabul kriterleri

- [x] [JVM] Deterministik bariyer testi: eski kuşak `awaitNext` içinde bekliyorken reconfigure + yeni CODEC_CONFIG/keyframe → kareler yalnız yeni kuşağa gider; eski kuşak hiçbirini göndermez.
- [x] [JVM] Mevcut T-158–T-161, T-168, T-208 testleri yeşil; kuyruk sınırlı kalır, en yeni kare kazanır.
- [ ] [device] 20 mod değişimi + 10 arka plan/ön plan: her seferinde görüntü ilk keyframe ile gelir, ek `kf_request reason=startup` tekrarı yok.

## Plan

1. **Kırmızı commit** (`test/.../video/DecoderQueueOwnershipTest.kt`, T-158 sahtesi): sahte codec'e
   `dequeueInputGate` (giriş tamponu alımı kapıda bekler, `dequeueInput#n>`/`<` olayları) ve codec başına
   gönderilen girişlerin pts listesi eklenir. Senaryo: kuşak 1'in giriş döngüsü `att.active` denetimini geçmiş,
   `prefetch` içinde kapıda bekliyor → `reconfigure` (kuşak 2, `acquire`'da bekler) → yeni CODEC_CONFIG + keyframe
   → kapı açılır. Beklenen: codec 1 yeni karelerin hiçbirini almaz, codec 2 ikisini sırayla alır. HEAD'de başarısız;
   `@Ignore` ile, başarısız çıktı commit mesajında.
2. **`FrameQueue.kt` — tüketici kuşak sahipliği:** kilit altında `owner` (0 = yok). `assignConsumer(gen)` /
   `revokeConsumer(gen)` (yalnız sahipse) — ikisi de kilitten sonra bekleyeni `unpark` eder. `awaitNext(timeoutNs,
   consumer)`: kare yalnız `consumer == owner` iken kilit altında alınır; sahip olmayan tüketici kare almadan hemen
   `null` döner (kare kuyrukta yeni kuşağa kalır). `ANY_CONSUMER` (varsayılan) sahiplik denetimi yapmaz (tek
   tüketicili kullanımlar/testler). Karar yolundan çağrılan `resetIfOwner(consumer, reason)` ve
   `onDecoderErrorIfOwner(consumer)`: sahip değilse hiçbir şeyi değiştirmez, istek üretmez (`null`) — emekliye ayrılan
   kuşak yeni kuşağın karelerini silemez. `waiter` yalnız kendi kaydıysa temizlenir. Sınır, en yeni kare, kapı ve
   istek limiti aynen.
3. **`VideoRenderer.kt`:** `retire()` önce `handoff.retire` (active=false), sonra `queue.revokeConsumer(gen)` (park
   etmiş eski tüketici hemen uyanır ve çıkar). `start()` iş parçacığı başlamadan `queue.assignConsumer(gen)` (yani
   `onConfigInstalled`'dan önce). Giriş döngüsü `awaitNext(..., att.gen)`; `frame_too_large` ve `decode_error`
   sonrası sıfırlama `...IfOwner(att.gen)` ile (sahip değilse döngüden çıkar). Kilit altında dışarı çağrı yok.
4. **Testler (yeşil):** kırmızı testin `@Ignore`'u kalkar; ek olarak eski tüketicinin `awaitNext` içinde park
   halinde tutulduğu ikinci bariyer varyantı (`FrameQueue` iç test kancası, park öncesi); saf `FrameQueue`
   sahiplik testleri (sahipsiz tüketici boş döner ve kare kalır; sahipsiz aralıkta kuyruk sınırlı; `IfOwner`
   no-op; revoke park eden tüketiciyi uyandırır). T-158–T-161, T-168, T-208 testleri yeşil kalır.

## Handoff

- **Commit:** `987994b` (fix) on branch `task/T-219-client-decoder-queue-generation-ownership`. Red step: `edef74c`
  (`@Ignore`d; at `0fe42ef` it failed with `the retired generation submitted the next generation's frames
  expected:<[]> but was:<[10]>`). Plan: `0fe42ef`. Final SHA: the Handoff commit on top of these.
- **Dokunulan dosyalar:**
  - `video/FrameQueue.kt`: owner generation (`NO_CONSUMER` = 0; `ANY_CONSUMER` = -1 skips the check, used by the
    old call sites/tests). `assignConsumer(gen)`, `revokeConsumer(gen)` (only if still owner); both unpark the parked
    consumer after leaving the lock. `awaitNext(timeoutNs, consumer)`: ownership check and removal are one step under
    the queue lock; a non-owner returns null at once (also after a wake-up) and leaves the frames queued.
    `resetIfOwner(consumer, reason, keepConfig)` / `onDecoderErrorIfOwner(consumer)`: no-op and null for a non-owner
    (`reset` / `onDecoderError` delegate with `ANY_CONSUMER`, unchanged). `waiter` is cleared only by its own thread.
    Test hook `parkHook` (internal). Bound, overflow, keyframe gate and request limit unchanged.
  - `video/VideoRenderer.kt`: `start()` assigns the queue to the new generation before its thread starts (so before
    `onConfigInstalled` and any frame of the new config); `retire()` revokes it right after `handoff.retire` (active=false
    first, so the old loop exits instead of spinning); give-up revokes too. Input loop `awaitNext(…, att.gen)`;
    `frame_too_large` → `onDecoderErrorIfOwner(att.gen)`; codec restart after `decode_error` → `resetIfOwner(att.gen)`,
    and the loop ends if the generation lost ownership. Test hook `inputParkHook` (internal). No call-out under a
    lock (queue lock only for the owner field; unpark/onRequest/onKeyframeRequest outside); T-161 bounded retire as is.
  - Tests: `DecoderQueueOwnershipTest.kt` (new, 2 renderer barrier tests: old input thread held after its `active`
    check in `prefetch` via the fake's `dequeueInputGate`, and held inside the queue wait right before the park);
    `FrameQueueOwnershipTest.kt` (new, 6 pure tests); `FakeDecoderCodec.kt` (`dequeueInputGate`, per-codec `inputPts`).
- **Testler:** both barrier tests: codec 1 receives none of generation 2's frames, codec 2 gets `[CODEC_CONFIG,
  keyframe]` in order, `Running(2)`. With the ownership check disabled both fail (`[10]` resp. `[0, 1, 10]` on codec 1).
  Pure: a replaced consumer takes nothing and does not park; while unowned the queue stays bounded (overflow →
  FRAMES_DROPPED) and the next owner gets config + newest keyframe; a late revoke of an older generation keeps the
  owner; a non-owner cannot reset/fail the queue (no request, counters unchanged); revoke / a new owner wake a parked
  consumer at once with null. Ownership/teardown/lifecycle/handoff/health tests rerun 6× green; `./scripts/check.sh`:
  ALL OK.
- **Varsayımlar:**
  - A frame the old loop took *before* the revoke was offered before the reconfigure's `queue.reset` and belongs to the
    old stream (the reset would have dropped it); losing it is correct. Revoke always precedes the reset.
  - Frames offered between `retire()` and `start()` (no owner) wait in the queue, bounded as always, for the next
    generation; `attachTarget`'s reset then clears them as before.
  - A stuck generation (T-161 `Stuck`) still owns the queue but consumes nothing; feeding is blocked then, and the
    next `start()` reassigns.
  - Side effect: a retired input loop parked in the queue wait now wakes at the revoke instead of after its park
    timeout (4–20 ms), so the next generation's hand-off can start that much earlier.
- **Test edilmeyenler / cihazda doğrulanacaklar (nothing ran on the tablet):**
  1. Normal USB connect: image appears with `MB/decoder ev=codec_start`, `video_health state=healthy`.
  2. 20× mode change (Netlik ↔ Akıcı ↔ Oyun 60): each time the image returns with the first keyframe; per change one
     `kf_request reason=… src=reset` from the reconfigure and **no** extra `kf_request … src=retry` (startup retry) and
     no `decode_error` on the new codec.
  3. 10× background/foreground: same (one reset request per attach, image back at the first keyframe).
  4. Over the run: `detach_slow`, `decoder_previous_stuck`, `retire_lock_slow` stay 0; `mb-decoder` thread count back to
     baseline.
- **Açık sorular:** none. No new log lines; no wire change.
