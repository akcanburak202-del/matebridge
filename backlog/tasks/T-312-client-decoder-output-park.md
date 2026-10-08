---
id: T-312
title: Tablet — codec boşken çözücü çıkış iş parçacığı park eder (CB2, A/B anahtarı); Tam renk aux çözücü ve GL beklemesi olay tabanlı (C10/CB9)
status: todo
phase: 7
owner: android-client-dev
depends_on: [T-303]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-312-client-decoder-output-park.md
---

## Amaç

T-298 CB2 (`docs/reviews/2026-10-08/agents/opt-b-client.md`) ve T-297 C10. T-296 tabanı: kaydırma ve hareket sahnelerinde çözücü yolu ~1.900 uyanma/s (`MediaCodec_loop` ~780, `mb-decoder-out` ~515, `CodecLooper` ~430). Çıkış iş parçacığı, son 300 ms içinde çıktı geldiyse codec boş olsa bile 5 ms'de bir yokluyor. Zaman aşımına uğrayan her senkron dequeue iki looper uyanması daha getiriyor.

## Kabul

1. **Sayaç:** çıkış iş parçacığı, codec'e verilen (CODEC_CONFIG hariç) ve alınan karelerin farkını izler.
2. **Park:** fark 0 ve tutulan tampon yoksa iş parçacığı `LockSupport.park`'a girer. Giriş iş parçacığı `queueInputBuffer` sonrasında ve emeklilikte (retire) `unpark` eder. Sigorta 20 ms.
3. Kare uçuştayken 5 ms dequeue aynen kalır. **Uzun dequeue yok.**
4. **A/B anahtarı:** `--es dec_out_park off|on`, varsayılan `off`. DevKnobs ve `ev=profile knobs=`. Benimsenirse varsayılan değişir.
5. **Davranış:** 0019 kuşak, emeklilik ve sahiplik kuralları ile `FirstOutputBypass` değişmez. `DecoderLifecycleTest`, `GenerationHandoffTest` ve diğerleri geçer; park ve unpark yolu için yeni testler (kaçan unpark → sigorta).
6. **C10:**
   - `AuxDecoder` giriş iş parçacığı 4 ms `awaitNext` yerine olay park eder (`DecoderWaits.EVENT_INPUT_WAIT_NS` gibi uzun sigorta).
   - Çıkış `IdleWait` kullanır.
   - `PackedPresenter` GL 25 ms beklemesi yalnız bildirimle uyanır (sigorta korunur).
   - Bekçi (2 s) en geç 250 ms'de bir kontrol edilir.
7. **Cihaz A/B (orkestratör, T-286 yöntemi):** `/proc` iş parçacığı uyanmaları ve `cap_dec` p50/p95 ±1 ms, 10 fps ve hareket sahnesi.

## Plan

## Handoff

## Open questions
