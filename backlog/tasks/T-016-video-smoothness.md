---
id: T-016
title: Görüntü akıcılığı — kare zamanlaması, 120 Hz, titreşim ölçümü
status: todo
phase: 1
owner: android-client-dev
depends_on: [T-015]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
---

## Amaç

İlk canlı testte (NOTES 2026-09-29) 56–59 fps'e rağmen kullanıcı "hafif takılma, ara ara fps düşüşü" gördü. Tablet 60 Hz'de ve kareler çözülür çözülmez çiziliyor. Hedef: hareketli içerikte gözle görülür takılma olmadan, gecikmeyi en fazla ~1 kare artırarak akıcı gösterim.

## Kabul kriterleri

- [ ] **Ölçüm önce:** kare varış aralığı (network), çözme sonrası hazır olma aralığı ve ekrana gösterim aralığı için histogram/yüzdelik (p50/p95/p99, 16,7 ms'yi aşan aralık sayısı) saniyede bir `MB/render` loguna ve istatistik katmanına. Saf kısmı JVM testli.
- [ ] **Yenileme hızı:** akış sırasında pencere için `preferredDisplayModeId`/`Surface.setFrameRate` ile 120 Hz (desteklenen en yakın) tercih edilir, akış bitince bırakılır. Seçilen mod loglanır.
- [ ] **Kare zamanlaması:** `Choreographer` vsync'ine hizalı sunum. `releaseOutputBuffer(index, renderTimestampNs)` ile her kare bir sonraki uygun vsync'e planlanır. Küçük, ayarlanabilir bir titreşim tamponu (varsayılan 1 kare, en çok 2) ve "en yeni kare kazanır" kuralı korunur (§5). Tampon 0'a ayarlanabilir (şimdiki davranış), karşılaştırma için.
- [ ] İstatistik katmanında seçili mod (60/120 Hz), tampon ve yukarıdaki yüzdelikler görünür.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar

- Orkestratör, Mac'teki 60 fps test sayfasıyla (Safari animasyonu) önce/sonra ölçümü yapar ve kullanıcıya gözle değerlendirtir.
- Gecikme hedefi: ölçülen uçtan uca gecikme (şu an ~39 ms) en fazla ~17 ms artmalı.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
