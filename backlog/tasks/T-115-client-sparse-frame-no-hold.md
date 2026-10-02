---
id: T-115
title: Tablet — seyrek karelerde (boşluktan sonraki ilk kare) kilit tutmasını kaldır; boşta görüntü gecikmesi bir vsync azalsın
status: review
phase: 5
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/PaceTrace.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - tools/pacing/
  - backlog/tasks/T-115-client-sparse-frame-no-hold.md
---

## Amaç

NOTES 2026-10-02 ~09:20 (gecikme dökümü): panel 60 Hz, boşta masaüstü (~10 fps; yazı, imleç, hareketin ilk karesi) iken her kare `pace_add_ms=16.67`, `d_us=16666`. Yani kilit pacer'ı her kareye bilerek bir tam vsync ekliyor.

Nedeni:
- Seyrek kare (`captureUs − prevCaptureUs > LOCK_GAP_PERIODS × period`) her seferinde kilidi yeniden ediniyor (`scheduleLocked` → `acquire()`).
- `acquire()` slotu `ideal + d` ve `ideal + j/2` altına koymuyor.
- `d` ve `j`, boşluktan sonraki "soğuk" karelerin şişirdiği 256 örneklik jitter geçmişinden geliyor (p99 → tavan bir periyot).

Tek başına gelen bir karede bu tutma hiçbir akıcılık kazandırmıyor; yalnızca gecikme ekliyor.

Hedef: seyrek/ilk kare `earliest` slota gitsin. Kazanç 60 Hz'te ~16,7 ms, 120 Hz'te ~8,3 ms. Sürekli harekette akıcılık bozulmamalı.

## Kapsam dışı

- Sürekli akıştaki kilit davranışı (p99 yüzdeliği, merkezleme, gecikme sınırı T-057). Sürekli akışın ilk birkaç karesinin kilide geçişi kapsamda.
- Oyun modu / `jitter 0` yolu (zaten tutmasız).
- `ConstantPlayoutPacer` (`--es pacer cpd`).
- Çözücü, host, protokol.

## Kabul kriterleri

- [x] Seyrek kare (kilit ediniminde `sparse` ya da ilk kare) `earliest` slotuna planlanır (ek tutma 0). Böyle karelerin sapması jitter geçmişine **girmez** ya da sürekli akış istatistiğini bozmayacak biçimde ayrı tutulur. Plan'da gerekçelendirilir.
- [x] Seyrek kareden sonra sürekli akış başlarsa kilit, T-065 kuralını bozmadan oturur: bir kare ancak daha yeni bir kare yerini alırsa atılabilir. Kilit en geç 2. ardışık karede kurulabilir; ilk karenin erken slotu sonraki karelerin geç atılmasına yol açmamalı.
- [x] Birim testleri:
  - (a) 60 ve 120 Hz'te 100 ms aralıklı seyrek karelerde `pace_add = 0`;
  - (b) seyrek → sürekli 60 fps geçişinde atılan kare yok ve çift slot yok;
  - (c) mevcut `AdaptivePacerTest`, `PhaseLockTest`, `LockRecenterTest`, `NewestFrameShownTest` geçer.
- [x] `tools/pacing/` ile `trace7_120hz_excerpt.csv` üzerinde eski/yeni karşılaştırması (`sim.py` ya da küçük ek bir betik): sürekli bölümde boşluk/atma oranı değişmiyor, seyrek bölümde gecikme düşüyor. Sonuç *Handoff*'a.
- [x] `PaceProbe` yolu yeni dalı ayırt eder (pace_trace analizinde görülebilsin).
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

Kapsam yalnız kilitlenebilir yol (`lockable`: içerik aralığı ≈ panel periyodu). Kilitsiz yol değişmez.

1. **"Taze" kare tanımı:** `lockable` ve (önceki kare yok ya da yakalama boşluğu > `LOCK_GAP_PERIODS` × P). Yani mevcut `sparse` + ilk kare (oturum başı, 1 s boşta kalma sonrası `reanchor`, panel hızı değişimi).
2. **Taze kare → `earliest`:** `scheduleLocked` taze karede `acquire()` çağırmaz. Slot = `earliest`, `addedNs = 0`.
   - Kilit kurulmaz (`lockSlot = MIN`, `phaseLock = false`, `badRun`/T-067 penceresi sıfır).
   - Önceki karenin slotu henüz gelmemişse (`earliest ≤ lastSlot`) eski davranış korunur: aynı slot, yeni kare eskisinin yerine geçer (T-065).
3. **Kilit 2. ardışık karede kurulur:** taze kareden sonraki sürekli kare, mevcut edinim dalına (`PATH_ACQUIRE`) düşer: merkezli `acquire()`, kod değişmedi.
   - *Uygulamada değişti (ilk plan: `lastSlot + P`'ye itmek).* Benzetimde itme kötü çıktı. Soğuk 1. kare, 2. karenin merkezli slotunu işgal ettiğinde kilit bir P geç kuruluyor, 30 kare sonra yeniden fazlamada hareketin ortasında bir kare kayboluyordu.
   - Bu yüzden eski kural kaldı: 2. kare aynı vsync'te tek kareyi değiştirir (T-065, daha yeni kare). Ekrana çıkış anı aynı, kilit merkezde.
   - Bilinen bedel (soğuk olmayan kare): 1. karenin kazandığı vsync, 1. ile 2. kare arasında tek bir tekrarlanan vsync olarak görünebilir. Sonrası kilitli ve düzgün.
3b. **Isınma (ek):** 2. karede edinim neredeyse boş jitter geçmişiyle yapılır (taze kareler geçmişe girmiyor). Benzetimde bu, ilk karelerde geç atma zincirlerine yol açtı.
   - Kural: geçmiş `WARMUP_SAMPLES = 32` örnekten azken, geç kalan kilitli kare kilidi hemen kendi zamanlamasından yeniden edinir (`PATH_WARMUP`).
   - Slotu kaçırdıysa yeni slot daha geç olur: tek tekrarlanan vsync, atma yok.
   - Kilit çok geç kurulduysa (gecikme sınırı aşıldıysa) yeni slot daha erkendir. Önceki slota düşerse aynı vsync'te değiştirme olur; bu `lateDrop` sayılır, sonuç geç atmayla aynıdır. 30 karelik zincir oluşmaz.
   - Toplu teslimde (`readyGap < captureGap/2`) eski sınır kuralı geçerli.
   - T-067 `recenter` açıkken devre dışı.
4. **Jitter geçmişi:** taze karelerin `dev` değeri 256 örneklik geçmişe **girmez**.
   - Gerekçe: bu kareler artık tutma almıyor, yani D'ye ihtiyaçları yok. Soğuk-kare sapması (DVFS, boşta çözücü) sürekli akışın jitter'ı değil; geçmişe girince p99'u tavana (1 P) itiyor ve sürekli akışa da gereksiz bir vsync ekliyor.
   - Taban `b` (min penceresi) değişmez: soğuk kare minimumu düşüremez, yalnız üst sınır.
5. **A/B anahtarı:** `AdaptivePacer.sparseEarly` (varsayılan `true`; `false` = eski davranış). Yalnız iz tekrar karşılaştırması ve olası cihaz A/B'si için; intent bağlantısı kapsam dışı (`MainActivity` listede yok).
   - Iz tekrarı için `internal scheduleOn(grid, …)`. `schedule()` bunu `vsync.grid()` ile çağırır, davranış aynı.
6. **PaceProbe:** yeni yollar `PATH_EARLY_SPARSE = 8` (`early_sparse`), `PATH_EARLY_FIRST = 9` (`early_first`) ve `PATH_WARMUP = 10` (`warmup`). `acquire_ns` sütununa eski tutmanın vereceği slot yazılır, böylece kazanç izde `acquire_ns − slot_ns` olarak okunur. `PATH_SPARSE` eski izler için kalır.
7. **Testler (`video/`):**
   - `SparseFrameNoHoldTest`:
     - (a) 60/120 Hz, 100 ms aralık, soğuk kareler dahil → `addedNs = 0`.
     - (a′) Uzun seyrek dönemden sonra sürekli akışta D tavanda değil.
     - (b) Seyrek → sürekli (60 ve 120 Hz panel, `SlotReleaser` ile). Titreşimsiz akışta atma ve çift slot yok, geçişte en çok bir tekrar. Titreşimli taramada eskiyle karşılaştırma yapılır.
     - Soğuk ilk kare varyantı.
     - Isınma.
   - İz tekrarı (`trace7_120hz_excerpt.csv`, eski/yeni): sürekli bölümde boşluk/atma, seyrek bölümde gecikme.
   - `PaceTraceTest`: yeni yol adları.
   - Mevcut testler: iki testin önkoşulu değişti (bkz. Handoff), diğerleri aynen geçiyor.
8. `tools/pacing/README.md`: tekrar testinin nasıl çalıştırılacağı.

## Handoff

- **Commit:** `eb5fe32` (uygulama). Plan `beefd1b`; bu Handoff ayrı commit. Dal `task/T-115-sparse-frame-no-hold`.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt`
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/PaceTrace.kt` (yeni yollar: `early_sparse`=8, `early_first`=9, `warmup`=10)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/video/SparseFrameNoHoldTest.kt` (yeni)
  - `PaceTraceTest.kt`, `LockRecenterTest.kt`, `PresentationSchedulingTest.kt` (aşağıya bkz.)
  - `tools/pacing/README.md`
- **Ne değişti (yalnız kilitlenebilir yol):**
  - Tek kare (ilk kare ya da > 3 P yakalama boşluğu) `earliest` slota gider (`pace_add = 0`). Kilit kurmaz, sapması jitter geçmişine girmez.
  - Kilit sonraki sürekli karede mevcut edinimle kurulur.
  - Geçmiş 32 örnekten azken geç kalan kilitli kare kilidi hemen yeniden edinir (ısınma; `recenter` açıkken ve toplu teslimde devre dışı).
  - `sparseEarly = false` eski davranışın birebir aynısıdır (A/B, şimdilik yalnız testlerde).
- **Ölçümler** (birim test çıktısı):
  - **(a) 100 ms aralıklı tek kareler, 0–20 ms soğuk sapma, 8 faz:**
    - yeni `pace_add` = 0;
    - eski ortalama 7,0 ms (60 Hz) / 3,0 ms (120 Hz).
    - Cihazdaki 16,7 ms (D tavanda) bundan da kötüydü, çünkü D tavana çıkmıştı.
  - **(a′) Uzun boşta kalmadan sonra hareketin 0,5. saniyesinde D:**
    - yeni 2,5 ms;
    - eski 11,9 ms (60 Hz) / 8,3 ms (120 Hz).
    - Hareket sırasında da gecikme ~4 ms düşüyor (60 Hz: 13,9 → 9,8 ms; 120 Hz: 9,8 → 5,7 ms, ready→slot).
  - **(b) Seyrek → sürekli, 0–2 ms titreşim, 720 hareket, çakışma/geç atma/boşluk:**
    - 60 Hz: yeni 10/0/68, eski 22/0/3;
    - 120 Hz: yeni 23/1/140, eski 51/13/17.
    - "Boşluk" çoğunlukla geçişteki tek tekrarlanan vsync (1. kare erken, kilit merkezde).
    - Titreşimsiz akışta 16 fazın hepsinde: atma yok, çift slot yok, kilit 2. karede, 3. kareden itibaren adımlar tam 1 P.
  - **Soğuk ilk kare (hareketin 1. karesi +3/+6 ms), 720 hareket:**
    - 1. kare, aynı vsync'te 2. kare tarafından değiştiriliyor: 60 Hz'te 73/204, 120 Hz'te 144/398 harekette. Ekrana çıkış anı aynı, sonraki karelerde ek atma yok.
    - "Sonraki kare" atmaları eskiyle aynı ya da daha az (60 Hz +6: 8 / eski 30).
  - **`trace7_120hz_excerpt.csv` tekrarı:**

    | | tek kare (94) p50 / ort. | sürekli boşluk | sürekli atma | sürekli p50 |
    |---|---|---|---|---|
    | eski | 11,22 / 11,57 ms | 52 (%1,91) | 166 (%6,09) | 13,15 ms |
    | yeni | 10,81 / 10,42 ms | 59 (%2,16) | 144 (%5,28) | 13,16 ms |

    - Bu iz 120 Hz sürekli çizim; oradaki tek karelerin eski tutması küçüktü (ort. 1,15 ms), kazanç da küçük.
    - Asıl kazanç boşta 60 Hz masaüstünde beklenir.
- **Varsayımlar:**
  - Tek kare tanımı mevcut `LOCK_GAP_PERIODS` (3 P).
  - Isınma eşiği 32 örnek (p99 = maksimum).
  - Kilitsiz yol (ör. 120 Hz panelde 60 fps) değişmedi.
- **Değişen mevcut testler (önkoşul değişti, davranış hatası değil):**
  - `LockRecenterTest.earlyLockIsRecentredByTheLateFrameRate`: tohum 12 → 0.
    - Kilit artık 2. karede kuruluyor. Tohum 12 ile yeni edinim erken düşmüyor: ilk saniyede 0 geç kare, eskide 6. Yani yeniden merkezlenecek bir şey kalmıyor.
    - Tohum 0 senaryoyu yeniden kuruyor: 4 geç kare, 1 recenter.
  - `PacerLatencyBoundTest.burstBeyondBoundCollidesInsteadOfQueueing`: `lateDrops >= 8` → `>= 7`. Taze pacer'da 0. kare tek kare, 1. kare kilidi ediniyor; geç atmalar bir kare sonra başlıyor.
  - `AdaptivePacerTest`, `PhaseLockTest`, `NewestFrameShownTest` aynen geçiyor. `./scripts/check.sh`: ALL OK.
- **Cihazda doğrulanacaklar** (`--ez pace_trace true` ile iz alınabilir):
  1. 60 Hz boşta masaüstü, yazı ve imleç: STATS'ta `pace_add` ~0 olmalı (önce 16,67), `D` tavanda (16,7) olmamalı, `video_ms` ~17 ms düşmeli.
     - Not: boşta `phase_lock=0` görünür, çünkü tek karede kilit yok.
  2. Pace izinde boşta karelerin yolu `early_sparse` (ilk kare `early_first`); `acquire_ns − slot_ns` kazancı gösterir.
  3. Sürekli hareket (pencere sürükleme, kaydırma, 120 Hz kalemle çizim): akıcılık değişmemeli. STATS'ta `skip%`/`late_drop`/`slot_dup` önceki oturumlarla aynı düzeyde olmalı.
     - Hareket başında tek bir kare tekrarı olabilir (beklenen).
     - Hareketin ~0,25–0,5 s'sinde tekrarlayan bir takılma olmamalı.
  4. Hareket başında ilk karelerde `warmup` yolu birkaç kez görülebilir; oturum ortasında (geçmiş dolunca) görülmemeli.
  5. Oyun modu / `cpd` pacer etkilenmemeli (dokunulmadı).
- **Açık sorular:**
  - `sparseEarly` için intent anahtarı (ör. `--ez sparse_early false`) cihaz A/B'si için yararlı olur, ama `MainActivity` bu kartın `files:` listesinde değil. Gerekirse küçük bir takip kartı.
  - Soğuk ilk karenin 2. kare tarafından değiştirilmesi `slot_dup`/`collided` sayaçlarında görünür, ama görsel kayıp yok. STATS yorumlanırken akılda tutulmalı.
