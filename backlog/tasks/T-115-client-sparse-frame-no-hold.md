---
id: T-115
title: Tablet — seyrek karelerde (boşluktan sonraki ilk kare) kilit tutmasını kaldır; boşta görüntü gecikmesi bir vsync azalsın
status: todo
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

- [ ] Seyrek kare (kilit ediniminde `sparse` ya da ilk kare) `earliest` slotuna planlanır (ek tutma 0). Böyle karelerin sapması jitter geçmişine **girmez** ya da sürekli akış istatistiğini bozmayacak biçimde ayrı tutulur. Plan'da gerekçelendirilir.
- [ ] Seyrek kareden sonra sürekli akış başlarsa kilit, T-065 kuralını bozmadan oturur: bir kare ancak daha yeni bir kare yerini alırsa atılabilir. Kilit en geç 2. ardışık karede kurulabilir; ilk karenin erken slotu sonraki karelerin geç atılmasına yol açmamalı.
- [ ] Birim testleri:
  - (a) 60 ve 120 Hz'te 100 ms aralıklı seyrek karelerde `pace_add = 0`;
  - (b) seyrek → sürekli 60 fps geçişinde atılan kare yok ve çift slot yok;
  - (c) mevcut `AdaptivePacerTest`, `PhaseLockTest`, `LockRecenterTest`, `NewestFrameShownTest` geçer.
- [ ] `tools/pacing/` ile `trace7_120hz_excerpt.csv` üzerinde eski/yeni karşılaştırması (`sim.py` ya da küçük ek bir betik): sürekli bölümde boşluk/atma oranı değişmiyor, seyrek bölümde gecikme düşüyor. Sonuç *Handoff*'a.
- [ ] `PaceProbe` yolu yeni dalı ayırt eder (pace_trace analizinde görülebilsin).
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

Kapsam yalnız kilitlenebilir yol (`lockable`: içerik aralığı ≈ panel periyodu). Kilitsiz yol değişmez.

1. **"Taze" kare tanımı:** `lockable` ve (önceki kare yok ya da yakalama boşluğu > `LOCK_GAP_PERIODS` × P). Yani mevcut `sparse` + ilk kare (oturum başı, 1 s boşta kalma sonrası `reanchor`, panel hızı değişimi).
2. **Taze kare → `earliest`:** `scheduleLocked` taze karede `acquire()` çağırmaz. Slot = `earliest`, `addedNs = 0`.
   - Kilit kurulmaz (`lockSlot = MIN`, `phaseLock = false`, `badRun`/T-067 penceresi sıfır).
   - Önceki karenin slotu henüz gelmemişse (`earliest ≤ lastSlot`) eski davranış korunur: aynı slot, yeni kare eskisinin yerine geçer (T-065).
3. **Kilit 2. ardışık karede kurulur:** taze kareden sonraki sürekli kare, mevcut edinim dalına (`PATH_ACQUIRE`) düşer: merkezli `acquire()`.
   - Yeni kural: sürekli akıştaki bir edinim önceki karenin slotuna ya da daha erkenine düşerse `lastSlot + P` alır (çakışma/atma yok), kilit de oraya kurulur.
   - Gerekçe: erken gösterilen 1. kare, 2. karenin merkezli slotunu işgal edebilir. Aynı slotta yer değiştirme ya ilk kareyi atar ya da `SlotReleaser` taşıma zincirine yol açar. Bir sonraki boş slot ikisini de önler; gecikme sınırı içinde kalır (`lastSlot ≤ earliest₂`).
   - Bilinen bedel: 1. karenin kazandığı vsync, 1. ile 2. kare arasında tek bir boş vsync olarak görünebilir (hareket başında bir kare tekrarı). Sonrası kilitli ve düzgün.
   - Soğuk 1. kare kendi tutmasından > 1 P geç gelirse kilit bir P geç kurulur. Mevcut 30 karelik yeniden fazlama bunu bir çakışmayla düzeltir; bu, eski kodun aynı durumdaki davranışıdır.
4. **Jitter geçmişi:** taze karelerin `dev` değeri 256 örneklik geçmişe **girmez**.
   - Gerekçe: bu kareler artık tutma almıyor, yani D'ye ihtiyaçları yok. Soğuk-kare sapması (DVFS, boşta çözücü) sürekli akışın jitter'ı değil; geçmişe girince p99'u tavana (1 P) itiyor ve sürekli akışa da gereksiz bir vsync ekliyor.
   - Taban `b` (min penceresi) değişmez: soğuk kare minimumu düşüremez, yalnız üst sınır.
5. **A/B anahtarı:** `AdaptivePacer.sparseEarly` (varsayılan `true`; `false` = eski davranış). Yalnız iz tekrar karşılaştırması ve olası cihaz A/B'si için; intent bağlantısı kapsam dışı (`MainActivity` listede yok).
   - Iz tekrarı için `internal scheduleOn(grid, …)`. `schedule()` bunu `vsync.grid()` ile çağırır, davranış aynı.
6. **PaceProbe:** iki yeni yol, `PATH_EARLY_SPARSE = 8` (`early_sparse`) ve `PATH_EARLY_FIRST = 9` (`early_first`). `acquire_ns` sütununa eski tutmanın vereceği slot yazılır, böylece kazanç izde `acquire_ns − slot_ns` olarak okunur. `PATH_SPARSE` eski izler için kalır.
7. **Testler (`video/`):**
   - `SparseFrameNoHoldTest`: (a) 60/120 Hz, 100 ms aralık, soğuk kareler dahil → `addedNs = 0`; (a′) uzun seyrek dönemden sonra sürekli akışta D tavanda değil; (b) seyrek → sürekli 60 fps (60 ve 120 Hz panel, `SlotReleaser` ile) → atma yok, çift slot yok, geçişte en çok bir boşluk; soğuk ilk kare varyantı → `lateDrop` yok, en çok bir çakışma.
   - İz tekrarı (`trace7_120hz_excerpt.csv`, eski/yeni): sürekli bölümde boşluk/atma, seyrek bölümde gecikme.
   - `PaceTraceTest`: yeni yol adları.
   - Mevcut testler aynen geçmeli.
8. `tools/pacing/README.md`: tekrar testinin nasıl çalıştırılacağı.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
