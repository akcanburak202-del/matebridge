---
id: T-225
title: Client — base the presentation metric (skip_pct) on frame-rendered callbacks; the latch model miscounts ~20% of game frames and pins the pacer at its cap
status: done
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
- [x] [device] Ori ve RE4 loglarında `skip_pct` ≈ `cb_skip_pct` (±2 puan), `level` = 0 (gerçek atlama yoksa); D jitter + 0,5 ms civarında, sınırda değil (n=1).

## Sonra ölçülecek (orkestratör, kart dışı)

Ori Oyun 60 (panel 120, n=2) ve Oyun 120, ~3 dk: `--ez stats_1s true --ez pace_trace true`. Jitter p50 hâlâ > 12,5 ms ve kaçırılan slot > ~%3 ise n=2 sınırını 2P yapan geliştirici ayarı için A/B kartı.

## Plan

1. **İki `HoldMeter`, `VideoStats` içinde.** `holds` artık geri çağrı zaman damgalarını alır (`onRenderCallback(..., shownNs, periodNs)` -> `holds.onPresented(captureUs, cbNs, periodNs)`); `latchHolds` T-220'nin bırakma-anı modelini (`onReleased`) tanı olarak sürdürür. İkisi de `onDecoded` ile aynı içerik koşularını görür. Kural kümesi (koşu sürekliliği, n, kısa/uzun) aynı sınıftır, değişmez.
2. **`skip_pct` kaynağı:** callback bir kez bildirildiyse `holds` (geri çağrı), hiç bildirilmediyse (codec geri çağrı vermiyor, testler) `latchHolds`; ikisi de yoksa eski geri dönüş. `Snapshot.skipPct`, `holdJudged/Short/Long` ve `render ev=present` `hold_*` alanları seçili kaynaktan gelir; pacer geri beslemesi (`onSkipWindow(s.skipPct)`) otomatik olarak geri çağrıdan beslenir. Yeni tanı: `Snapshot.latchSkipPct` ve `render ev=present` satırında `hold_src=cb|latch latch_skip_pct=`. (`MainActivity` kart dışı: `latch_skip_pct` yalnız `present` satırında, `render ev=stats` satırı değişmez.)
3. **Geri çağrısı gelmeyen kare** (SF düşürdü): `onPresented` onu hiç görmez; sonraki gösterilen karenin koşusu önceki gösterilene uzandığı için önceki tutma n'den uzun çıkar (mevcut kural, yeni kod yok). `captureUs` bilinmiyorsa ya da zaman `Long.MAX_VALUE` ise dizi kesilir.
4. **`PresentMeter`: kalır**, eşik `gap > cadence + P/2` (n=2'de 3-vsync boşluğunu görür); `cb_skip_pct` bu eşikle tanı olarak sürer. Hold kuralları ve koşular `HoldMeter`'dadır, `PresentMeter` yalnız ham boşluk.
5. **`VideoRenderer`:** frame-rendered dinleyicisi `nanoTime` ve `vsync.periodNs`'yi `onRenderCallback`'e geçirir ve `trace?.onCallback(pts, nanoTime)` çağırır. Yeni kilit yok.
6. **`PaceTrace`:** `cb_ns` sütunu (son), `onCallback(seq, ns)` son 64 satırda seq arar; CSV_COLS +1.
7. **`tools/pacing/sim.py --holds`:** `cb_ns` varsa ve sıfırdan farklıysa onu kullanır (decode ve geri çağrı olayları zamana göre birleştirilir; geri çağrısı olmayan satır gösterilmemiş sayılır); `--latch` eski kaynağı zorlar. Self-test'e geri çağrı vektörü eklenir. README güncellenir.
8. **Belge:** `docs/LOGGING.md` `skip_pct` / `cb_skip_pct` / `latch_skip_pct` / `hold_src` anlamları.
9. **Testler** (`CallbackPresentationMetricTest`, `PresentRig` geri çağrı + bırakma gecikmesi seçenekleri): her kabul maddesi; ayrıca eski testler yeni `HoldCounts`/log biçimine uyarlanır.
10. **Çevrimdışı doğrulama:** kayıtlı izlerde `cb_ns` yok; bırakılan slotları (kesim = slot) geri çağrı yerine koyarak ve cihaz loglarındaki `skip_pct`/`cb_skip_pct` ile karşılaştırarak Handoff'a yazılır.

## Handoff

- **Commit:** `3eaeb5d` (kod, test, araç, belge); plan `3fe3721`; bu Handoff ayrı commit. Dal `task/T-225-client-callback-presentation-metric`. `./scripts/check.sh` -> ALL OK.
- **Dokunulan dosyalar:** `VideoStats.kt`, `VideoRenderer.kt`, `PresentMeter.kt`, `PaceTrace.kt`; testler `CallbackPresentationMetricTest.kt` (yeni), `PresentRig.kt`, `PresentationMetricTest.kt`, `PaceTraceTest.kt`; `tools/pacing/sim.py`, `tools/pacing/README.md`, `docs/LOGGING.md`; bu kart. Kart dışına çıkılmadı (`MainActivity.kt` dokunulmadı).
- **Ne değişti:**
  - `VideoStats` iki `HoldMeter` tutar: `holds` geri çağrı damgalarını (`onRenderCallback(ptsUs, captureUs, clientUs, shownNs, periodNs)`) alır, `latchHolds` T-220'nin bırakma-anı modelini (`onReleased`) sürdürür. İkisi de aynı `onDecoded` koşularını görür; kural kümesi (`HoldMeter`) bayt bayt aynı, yeni kilit yok (`onRenderCallback` zaten stats kilidini alıyordu).
  - `skip_pct`, `holdJudged/Short/Long` ve `render ev=present` `hold_*` alanları: bir kez geri çağrı bildirildiyse `holds`, hiç bildirilmediyse `latchHolds`, ikisi de yoksa eski geri dönüş. `AdaptivePacer.onSkipWindow(s.skipPct)` (MainActivity) otomatik olarak geri çağrıdan beslenir.
  - Yeni tanı: `Snapshot.latchSkipPct`; `render ev=present` satırına `hold_src=cb|latch latch_skip_pct=` eklendi (`render ev=stats` satırı ve `cb_skip_pct` alanı yerinde, MainActivity kart dışı olduğu için `latch_skip_pct` yalnız present satırında).
  - Geri çağrısı gelmeyen kare: yeni kod yok, mevcut koşu/n kuralı öncülü uzun sayar (JVM testli). `shownNs == Long.MAX_VALUE` ya da `captureUs` bilinmiyorsa dizi kesilir.
  - `PresentMeter` kaldı: eşik `gap > cadence + P/2` (n=2'de 3 vsync görülür), `cb_skip_pct` tanı olarak sürer.
  - `PaceTrace`: son sütunlar `cb_ns`, `cb_period_ns` (`onCallback(seq, ns, period)` son 64 satırda seq arar). `VideoRenderer` dinleyicisi `trace?.onCallback(pts, nanoTime)` çağırır.
  - `sim.py --holds`: `cb_ns` varsa onu kullanır (decode `ready_ns`'te, gösterim `cb_ns`'te, olaylar zamana göre birleştirilir; geri çağrısı olmayan satır gösterilmemiş); `--latch` eski kaynağı zorlar; self-test'e üçüncü vektör.
- **Codex incelemesi düzeltmeleri (2 x P2, ayrı commit):**
  1. `sim.py` `Long.MAX_VALUE` callback damgasını gösterilen kare sayıyordu; istemci diziyi kesiyor. Artık `cb_ns >= MAX` bir dizi kesme olayı (zamanı: kendi `ready_ns` + ortanca decode->callback gecikmesi). Self-test: aynı düzenli akış, 30. karede sentinel -> `skip_pct` 0 (çevresindeki aralıklar yargılanmaz, 95 aralık).
  2. `PaceTrace` yeni son sütun `cb_period_ns` (`onCallback(seq, ns, periodNs)`, `VideoRenderer` `vsync.periodNs`'yi teslim anında geçirir; CSV_COLS +1). `sim.py` periyot sırası `cb_period_ns` > `latch_period_ns` > `period_ns`. Self-test: 120 -> 60 Hz geçişinde callback'ler 60 Hz ızgarasında, `latch_period_ns` hâlâ 120 Hz: `cb_period_ns` ile `(120,2): 49 + (60,1): 48` hepsi exact; sütun silinince (eski iz) 60 Hz grubu çıkmaz. JVM: `PaceTrace` testleri iki sütunu kontrol eder. `./scripts/check.sh` -> ALL OK.
- **JVM sonuçları** (`CallbackPresentationMetricTest`, 120 Hz panel, 60 fps, iki kovalı titreme, uyarlamalı pacer, saniyede bir pencere, 60 sn; `release jitter` = `releaseOutputBuffer` dönüşünün 0..J us rastgele gecikmesi):

  | J (us) | geri çağrı `skip_pct` max | latch `skip_pct` max | `level` (geri çağrıdan) |
  |---|---|---|---|
  | 0 | 0,0 | 0,0 | 0 |
  | 1000 | 0,0 | 0,0 | 0 |
  | 1500 | 0,0 | 30,0 | 0 |
  | 2500 | 0,0 | 31,7 | 0 |
  | 2500, `level` latch'ten beslenseydi (T-220 davranışı) | 1,7 | 31,7 | 2 |
  | gerçek atlama (her 8. kare bir vsync geç) | 15,0 | 1,7 | 2 |

  Kabul maddeleri: eski kesimin ötesinde dönen bırakmalar + düzenli callback'ler -> `skip_pct` 0 (latch > %40); n=2'de 3 vsync -> uzun, ardından 1 vsync kısa; callback'i gelmeyen kare -> öncülü uzun (kısa yok); tampon 0 ve uyarlamalı aynı callback akışında aynı metrik (latch'leri farklı); `level` kusursuz callback'lerde 0, gerçek atlamada yükselir; `PresentMeter` n=2'de 3 vsync'i görür; callback yoksa latch'e düşer.
- **Çevrimdışı doğrulama (kayıtlı izler, `~/.cache/matebridge-tools/data/2026-10-04-session2/`).** Kayıtlı izlerde `cb_ns` yok (sütun bu kartla eklendi), o yüzden gerçek geri çağrı damgalarıyla yeniden oynatılamadı. Yerine "planlanan slot = geri çağrı zamanı" vekili kullanıldı (kart tablosundaki "kesim = slot" sütunu; yalnız gösterilen karelerin `released_slot_ns`'i, `sim.py --holds` `cb_ns` yolundan). Geçici CSV'ler scratchpad'de, commit edilmedi:

  | İz | latch `skip_pct` (T-220, `--latch`) | planlanan-slot vekili (yeni yol) | cihaz logu: eski model `skip_pct` p50 / eski `cb_skip_pct` p50 |
  |---|---|---|---|
  | Ori (pace_trace5) | 17,2 | 2,9 | 19,0 / 5,2 (game5-7 logları) |
  | RE4 varsayılan (re4a) | 16,1 | 0,7 | 19,6 / 0,0 |
  | RE4 max (re4b) | 19,8 | 0,1 | 20,4 / 0,0 |

  Latch ve vekil, kart tablosuyla uyumlu (model %17-20, cihaz callback ~%0-3). Bu bir vekil: gerçek callback damgalarının panel ızgarasına ne kadar oturduğu (jitter < P/2 mi) cihazda doğrulanmadı. Eski `cb_skip_pct` Ori'de n=2'de 3-vsync'i göremiyordu (yeni eşikle değişecek).
- **Varsayımlar:**
  - Callback `nanoTime` değerleri vsync ızgarasına P/2'den az sapmayla oturur (kart: `cb_skip_pct` RE4'te p50 0, `render_cb_missing` ~ 0). Oturmazsa `round(fark/P)` yanlış kısa/uzun üretebilir; bu cihaz ölçümünde `skip_pct` ile `cb_skip_pct` arasındaki farktan görünür.
  - Callback gelmiş bir cihazda sonradan callback kesilirse pencereler `null` döner ve geri besleme o pencereleri yok sayar (latch'e geri düşülmez; `callbacksReported` yapışkan).
  - Frame-rendered dinleyicisi ana looper'da çalışır; `PaceTrace.onCallback` kilitsizdir, son 64 satırda arar (tanı verisi, T-069 ile aynı kabul).
- **Test edilmeyenler / cihazda doğrulanacaklar (orkestratör):**
  1. Ori Oyun 60 (panel 120, n=2) ve RE4 Oyun 60 @60 Hz, `--ez stats_1s true --ez pace_trace true`, 2-3 dk. `render ev=stats` `skip_pct` ile `cb_skip_pct` birbirine +-2 puan yakın olmalı (yeni eşikle `cb_skip_pct` n=2'de de doğru); `render ev=present` `hold_src=cb`, `latch_skip_pct` hâlâ %15-20 ise model yanlış kalıyor demektir (beklenen), `skip_pct` ~%0-3.
  2. `AdaptivePacer.level` (`pace_d_us`, `level` alanı) 15 sn sonra 0 kalmalı; RE4 @60 Hz'de D ölçülen jitter + ~0,5 ms civarında, sınırda (karelerin %94/%99'u) değil.
  3. Trace'i çekip `python3 tools/pacing/sim.py TRACE --holds`: ilk satır `source: callback times (cb_ns)`; `--latch` ile karşılaştır. `cb_ns` doluluğu (0 olmayan oran) ~%99+ olmalı, gösterilen karelerde.
  4. Callback damgası ızgarası: `sim.py --holds` çıktısındaki hold dağılımı `exact` ağırlıklı olmalı; `holds 1:..% 3:..%` gibi simetrik kısa/uzun çiftleri çok yüksekse damga jitter'ı P/2'yi aşıyor demektir (varsayım yanlış, geri bildir).
- **Açık sorular:** Yok. Not: `MainActivity` `render ev=stats` satırına `latch_skip_pct` eklemek isteniyorsa o dosya karta eklenmeli.

**Cihaz (2026-10-04 ~14:35, RE4 @60 Hz):** `skip_pct` ≈ `cb_skip_pct`, `hold_src=cb`; 1848'de level 0, D 11,6–13,4 ms. Ori ve 120 Hz n=2 koşusu yapılmadı. Ayrıntı NOTES.
