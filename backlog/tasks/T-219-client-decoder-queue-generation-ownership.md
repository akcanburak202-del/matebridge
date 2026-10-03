---
id: T-219
title: Decoder input queue: a retired generation must not consume the next generation's frames
status: in-progress
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

- [ ] [JVM] Deterministik bariyer testi: eski kuşak `awaitNext` içinde bekliyorken reconfigure + yeni CODEC_CONFIG/keyframe → kareler yalnız yeni kuşağa gider; eski kuşak hiçbirini göndermez.
- [ ] [JVM] Mevcut T-158–T-161, T-168, T-208 testleri yeşil; kuyruk sınırlı kalır, en yeni kare kazanır.
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

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
