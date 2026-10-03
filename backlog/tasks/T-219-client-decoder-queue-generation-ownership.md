---
id: T-219
title: Decoder input queue: a retired generation must not consume the next generation's frames
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
