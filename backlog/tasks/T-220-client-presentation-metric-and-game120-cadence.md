---
id: T-220
title: One presentation metric across pacers; infer 60 fps cadence in Oyun 120
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-208, T-211]
decisions: [0014]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameInterval.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt   # only if the interval provider needs measured arrivals
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - tools/pacing/sim.py
  - docs/LOGGING.md
  - backlog/tasks/T-220-client-presentation-metric-and-game120-cadence.md
---

## Amaç

gpt-6-astra değerlendirmesi: (1) `skip_pct` uyarlamalı zamanlayıcıda zamanlayıcı kararlarından, aksi hâlde `PresentMeter`'dan hesaplanıyor; T-208/T-211 A/B'sindeki "%10 → %0" birebir karşılaştırma değil. Ayrıca kadans 2'de kaçırılan slot dalı 3 vsync'lik aralık üretebilir ama karşılaştırma "1,5 × kadans'tan büyük" olduğu için atlama sayılmaz (`VideoStats.kt` ~:269, `AdaptivePacer.kt` ~:361). (2) `FrameInterval.resolve` içerik kadansını ölçülen varıştan genel olarak çıkarmıyor: Oyun 120'de (120 fps config) 120 Hz panelde 60 fps gelen oyun içeriği yine 1 periyot sayılır, 2:1 kilit kurulmaz.

## Bağlam

- Tek, zamanlayıcıdan bağımsız bir sunum ölçütü: bırakılan her karenin gerçek tutma süresi (vsync cinsinden), içerik kadansına göre doğru/kısa/uzun; iki zamanlayıcıda da aynı hesap. `skip_pct` bu ölçüte bağlanır; eski alan adı korunur ya da yeni ad + takma ad.
- İçerik kadansı: config fps'i yerine (ya da yanında) ölçülen yakalama aralığından tam sayı katı (1 veya 2) çıkarımı, histerezisle.
- `sim.py --holds` aynı ölçütü kullanır.

## Kabul kriterleri

- [ ] [JVM] Aynı sentetik akış iki zamanlayıcıda (tampon 0 ve uyarlamalı) aynı ölçütle raporlanır; 3 vsync tutma kadans 2'de "uzun" sayılır.
- [ ] [JVM] Oyun 120 config + 120 Hz panel + 60 fps içerik → 2:1 kilit kurulur; 120 fps içerik → 1:1, değişmez.
- [ ] [device] Ori Oyun 60 ve Oyun 120, dokunmayla 120 Hz: aynı ölçütle tampon 0 ve uyarlamalı karşılaştırması NOTES'a.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
