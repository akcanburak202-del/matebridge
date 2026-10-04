---
id: T-225
title: Client — base the presentation metric (skip_pct) on frame-rendered callbacks; the latch model miscounts ~20% of game frames and pins the pacer at its cap
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-220, T-222]
decisions: [0014]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/PresentMeter.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/PaceTrace.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - tools/pacing/sim.py
  - tools/pacing/README.md
  - docs/LOGGING.md
  - backlog/tasks/T-225-client-callback-presentation-metric.md
---

## Amaç

Cihaz oturumu 2'nin izleri (2026-10-04, Ori 1848×1214 Oyun 60 @120 Hz panel; RE4 Oyun 60 @60 Hz, operating rate varsayılan ve `max`) T-220'nin "model" sunum metriğinin (`skip_pct`) yanlış olduğunu gösterdi. Bu yanlış metrik `AdaptivePacer` geri beslemesini (`level`) yükseltip D'yi sınırına yapıştırıyor: gereksiz gecikme. Metrik, gerçek gösterimi yansıtan `onFrameRendered` geri çağrılarına dayanmalı.

## Bağlam (analiz: orkestratör alt ajanı, 2026-10-04; veri `~/.cache/matebridge-tools/data/2026-10-04-session2/`)

**Kök neden — latch modeli kesimi bırakma yolunun 1 ms içinde:**
- `HoldMeter.latchSlot` (`VideoStats.kt:414-420`) bir kareyi, `releaseOutputBuffer` döndükten **sonra** okunan saat + `grid.deadlineNs` (6 ms, `FramePacer.kt:32` `VsyncClock.DEFAULT_DEADLINE_NS`) slotu geçiyorsa sonraki vsync'e sayar (`VideoStats.kt:428-434`, `VideoRenderer.kt:700`).
- Pacer kareyi `slot − dispatchLeadNs()` = `slot − (deadline + DISPATCH_MARGIN_NS)` = slot − 7 ms'ye kadar tutar (`VideoRenderer.kt:93`, `:713-716`; `SlotReleaser.flushDue` `SlotReleaser.kt:73-75`). Oyun karelerinin ~%80'i bu yoldan gider; "zamanında bırakıldı" ile "geç sayıldı" arasında yalnız 1 ms var, iş parçacığı uyanması (0,2–0,8 ms) + codec çağrısı bunu tüketiyor.
- Bırakma slottan 6,0–6,2 ms önce başladıysa %99'u, 6,4–6,6'da %32'si, >7,5'te ≤%0,5'i geç sayılıyor.
- `latch_slot_ns ≠ released_slot_ns`: Ori %24,8, RE4 varsayılan %21,2, RE4 max %22,8.

| İz | model `skip_pct` p50 | cihaz `cb_skip_pct` p50 | planlanan slotlarla (kesim = slot) |
|---|---|---|---|
| Ori | 17,5 | 3,4 | 3,0 |
| RE4 varsayılan | 19,6 | 0,0 | 0,9 |
| RE4 max | 20,4 | 0,0 | 0,3 |

Çizim izlerinde (drawA/drawB) hata yok (iki metrik de p50 0).

**Pacer'a etkisi:** şişkin `skip_pct` (~%20 > `SKIP_HIGH_PCT` 3) `onSkipWindow` (`VideoRenderer.kt:146` → `AdaptivePacer.kt:424-433`) ile `level`'ı ~15 sn'de 1–2'ye çıkarıyor. İnmek için 5 pencere < %1 gerekiyor; inmiyor. `extraNs` P/2–P olunca D sınıra yapışıyor (`AdaptivePacer.kt:136`, `:205-207`). RE4 @60 Hz: ölçülen jitter p50 14,5/13,1 ms (sınır 16,7) ama D karelerin %94/%99'unda sınırda.

**Mevcut `cb_skip_pct` olduğu gibi kullanılamaz:** `PresentMeter` (`PresentMeter.kt:31`) `gap*2 > cadence*3` eşiğiyle n=2'de (120 Hz panelde 60 fps) 3-vsync tutmayı göremez (T-220'nin pacer'da düzelttiği hatanın aynısı). Callback damgaları bırakmadan ~31 ms sonra geliyor (istenen render zamanı değil), ama aralıklar için sabit fark önemsiz; `render_cb_missing` ≈ 0.

**İstenen:**
- `VideoStats.onRenderCallback`, T-220'nin `HoldMeter` kurallarını (koşu sürekliliği, n, kısa/uzun) **callback zaman damgalarıyla** besler: `holds.onPresented(captureUs, cbNs, periodNs)` (periyot `VideoRenderer.kt:556`'da zaten hesaplanıyor). `skip_pct` bu kaynaktan gelir; pacer geri beslemesi de bunu kullanır.
- Latch modeli yalnız tanı olarak kalır: `latch_skip_pct` (LOGGING'de belgelenir).
- `PresentMeter` eşiği `> cadence + P/2` olur ya da metre kaldırılır (planda seç; `cb_skip_pct` anlamı LOGGING'de güncellenir).
- `PaceTrace`'e `cb_ns` sütunu (sona); `tools/pacing/sim.py --holds` varsa `cb_ns`'i tercih eder.
- Yeni kilit yok: `onRenderCallback` ana looper'da zaten stats kilidini alıyor.

## Kapsam dışı

- n=2 için D sınırı (1,5P, T-208). Ori @120 Hz'de gerçek jitter (p99 dev p50 21,9 ms) sınırın üstünde; bu ayrı bir gecikme/akıcılık kararı. Bu kart sonrası ölçümle (aşağıda) ayrıca değerlendirilir.
- Host, protokol.

## Kabul kriterleri

- [ ] [JVM] Bırakmalar eski kesimin 0,5 ms ötesinde dönerken callback'ler düzenli 2 vsync arayla → `skip_pct` = 0.
- [ ] [JVM] n=2'de 3-vsync callback boşluğu → uzun sayılır (kısa/uzun çifti doğru).
- [ ] [JVM] Bırakılıp callback'i hiç gelmeyen kare (SF düşürdü) → öncülü uzun sayılır.
- [ ] [JVM] Tampon 0 ve adaptif pacer aynı callback akışında aynı metriği verir.
- [ ] [JVM] Callback tutmaları kusursuzken `AdaptivePacer.level` 0'da kalır; gerçek atlamalar varken eskisi gibi yükselir.
- [ ] [JVM] `PresentMeter` (kalırsa) n=2'de 3-vsync boşluğu görür.
- [ ] [device] Ori ve RE4 loglarında `skip_pct` ≈ `cb_skip_pct` (±2 puan), `level` = 0 (gerçek atlama yoksa); D jitter + 0,5 ms civarında, sınırda değil (n=1).

## Sonra ölçülecek (orkestratör, kart dışı)

Ori Oyun 60 (panel 120, n=2) ve Oyun 120, ~3 dk: `--ez stats_1s true --ez pace_trace true`. Jitter p50 hâlâ > 12,5 ms ve kaçırılan slot > ~%3 ise n=2 sınırını 2P yapan geliştirici ayarı için A/B kartı.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
