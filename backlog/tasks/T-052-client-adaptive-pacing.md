---
id: T-052
title: Tablet — uyarlanır kare zamanlaması (en az gecikmeyle takılmasız sunum, 60/120 Hz)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-050]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-052-client-adaptive-pacing.md
---

## Amaç

NOTES 2026-10-01 "Takılma ölçümü": Mac kareleri kusursuz 8,3 ms aralıkla gönderiyor; tablette sunumda vsync'lerin **%21'i atlanıyor** (iki kare aynı vsync'e düşüp sonra bir vsync boş kalıyor). `jitter=2` (2 karelik tampon) atlamayı %2'ye indiriyor ama +16,7 ms gecikme ekliyor; `jitter=1` (+8,35 ms) **hiç etkisiz** — büyük olasılıkla `FramePacer`/`drainOutput` mantığında hata. Kullanıcı hem düşük gecikme hem takılmasızlık istiyor; kalem kullanıyor.

## Kabul kriterleri

- [ ] **Neden analizi:** `jitter=1`'in neden etkisiz olduğu bulunur ve Handoff'ta açıklanır (ör. hedef zamanın vsync'e göre fazı, `releaseOutputBuffer(idx, ns)`'nin SurfaceFlinger'daki davranışı, aynı çekilişte (drain) iki kare, "collided" mantığı).
- [ ] **Uyarlanır zamanlama** (yeni varsayılan, surface ve GL yollarında): her kare, varış zamanlarının düzgünleştirilmiş fazına göre bir vsync'e atanır; ek bekleme `D` en az tutulur ve ölçülen atlama oranına göre ayarlanır (hedef: atlanan vsync < %2, `D` genelde ≤ 1 vsync; 60 ve 120 Hz'te çalışır; panel hızı değişince (60↔120, Huawei dokunma kuralı) yeniden kilitlenir). Birikme yok: sınırlı kuyruk, gecikince en yeni kare kazanır (AGENTS.md).
- [ ] **Ölçüm istatistikte:** `OnFrameRenderedListener` zamanlarından sunum aralığı histogramı → `MB/render` satırına `skip_pct` (1,5 vsync'ten uzun aralıklar, kare mevcutken), `pace_ms` (ortalama ek bekleme), `vsync_ms`. İstatistik katmanında da görünür.
- [ ] Eski `--ei jitter N` sabit tampon seçeneği deney için kalır; `--ei jitter -1` (ya da benzeri) uyarlanır modu kapatır.
- [ ] Saf zamanlama mantığı birim testli (sahte saat, vsync, dalgalanan çözme süreleri: atlama oranı ve ek gecikme sınırları). `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host. Cihaz ölçümü orkestratörde (`dumpsys SurfaceFlinger --latency`, scratch `pace.sh`).

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
