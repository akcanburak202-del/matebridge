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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
