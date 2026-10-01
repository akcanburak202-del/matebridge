---
id: T-067
title: Tablet — faz kilidi geç kare oranına göre yeniden ortalanır; boşta kalınca jitter geçmişi silinmez
status: review
phase: 5
owner: android-client-dev
depends_on: [T-065]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt
  - client-android/app/src/test/
  - backlog/tasks/T-067-client-lock-recenter.md
---

## Amaç

Cihaz ölçümü 2026-10-01 ~09:45 (host + tablet `main` 022b3b1, panel 60 Hz, akış 120→60 seyreltilmiş, içerik: Mac köşesinde her vsync renk değiştiren 16 pt kare, 1 s'den uzun boşluktan sonra başladı). SurfaceFlinger 14 sn pencerelerinde 33 ms boşluk oranı sırayla:
**%17,5 → 26,2 → 11,5 → 8,1 → 8,2 → 10,2 → 6,9 → 6,6 → 6,7 → 3,6 → 1,4 → 2,2** (3 dk). Tablet `ev=present`: `late_drops` 2–35/sn, `phase_lock=1`, `rephase` arada 1–2, `d_us=16666` (D periyot sınırında). `ready` (yakalama→çözüldü) p50 ~16,3 ms, p95 ~20,5 ms.

**Yorum (orkestratör):** (1) `reanchor()` (> 1 s boşluk) jitter geçmişini (`devs`) ve D'yi siliyor → ilk karelerde jitter ≈ 0 ile kilit erken bir slota ediniliyor; (2) kilit ancak **30 ardışık** kötü karede yeniden ediniliyor, geç kareler aralıklı olduğu için sayaç sürekli sıfırlanıyor → yanlış kilit dakikalarca kalıyor, her geç kare 60 Hz'te bir 33 ms boşluk. Kademeli düzelme ve ara sıra `rephase` bununla uyumlu. (Saat kayması da katkıda bulunabilir; aynı mekanizma onu da çözer.)

## Kabul kriterleri

- [ ] **Jitter geçmişi boşlukta korunur:** `reanchor()` kilidi, `lastSlot`'u ve faz/taban durumunu sıfırlar ama gecikme dağılımını (`devs`, mümkünse `dNs`) korur — boru hattının jitter'ı içerik boşluğuyla değişmez. Taban `baseNs` için yeniden ölçümün gerekip gerekmediğini gerekçelendir (sabit saat farkı; m penceresi). Epoch (panel hızı) değişiminde bugünkü tam sıfırlama kalabilir ya da periyoda göre ölçeklenir — seçimini gerekçelendir.
- [ ] **Oran tabanlı yeniden ortalama:** son N kilitli karede (ör. 60) geç kare (slot < earliest ya da gecikme sınırı aşımı) sayısı eşiği aşarsa (ör. ≥ 3, yani %5) kilit hemen bugünkü `acquire()` ile yeniden edinilir (daha geç slot → bir kez tek kare tekrarı, sonra temiz). Erkene kaydırma (gecikmeyi azaltma) bugünkü gibi temkinli kalır (ardışık koşul). `rephases` her ikisini sayar; ayrıca nedeni ayırt eden sayaç ekleyebilirsin (`StatsFormat` alanı eklersen karta yaz).
- [ ] Yeniden ortalamadan sonra aynı pencere hemen yeniden tetiklemez (pencere sıfırlanır).
- [ ] **Testler (önce kırmızı):** PhaseLockTest tarzı simülasyon, 60 Hz panel, 60 fps akış:
  - Soğuk başlangıç: ready = cap + 16 ms + jitter (çoğunlukla 0–4 ms, %1 olasılıkla 6–12 ms sıçrama); ilk 2 sn'den sonra geç kare oranı ≤ %1 (bugün: yanlış kilit uzun süre kalıyor — testte bugünkü kodun kötü olduğunu göster).
  - 1,5 s boşluk → yeniden başlama: boşluk sonrası ilk 1 sn'de geç kare oranı soğuk başlangıçtan belirgin düşük (geçmiş korunduğu için).
  - Yavaş saat kayması (tablet periyodu host aralığından 100 ppm farklı) 5 dk: geç kare oranı ≤ %1, yeniden ortalama sayısı makul (dakikada birkaç).
  - Mevcut T-060/T-065 testleri geçer.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- 6 ms öncü, host tarafı, GL yolu.

## Plan

1. `reanchor()` (>1 s boşluk): kilit, slot, pencere-minimum deque'si sıfırlanır; `devs`, `dNs`, `baseNs` korunur (saat farkı sabit, boşlukta ppm kayması << 1 ms, sonraki kareler tabanı zaten yeni minimuma çeker; jitter dağılımı içerik boşluğuyla değişmez). Epoch (panel hızı) değişiminde tam sıfırlama kalır: tüm yol yeniden zamanlanıyor, jitter dağılımı önceki hıza ait.
2. Kilitli karelerde son 60 karelik halka (dev, geç): geç = slot < earliest ya da gecikme sınırı aşımı. Pencere >= 12 kare ve geç >= 3 ise kilit `acquire()` ile yeniden edinilir; jitter tabanı (`floorNs`) penceredeki 3. büyük dev olur, böylece slot daha geç seçilir (bir kez tek kare tekrarı). `acquire()` taban dahil jitter kullandığı için badRun yeni kilidi hemen geri çevirmez. Taban kare başına 5 us azalır (~1 dk). Gecikme sınırını aşacak yeniden ortalama (ör. aynı anda gelen kare yığını) yapılmaz, eskisi gibi düşürülür. `rephases` her ikisini sayar, `recenters` ayrıca nedeni ayırır (StatsFormat'a eklenmedi).
3. Testler: `LockRecenterTest` (soğuk başlangıç, boşluk sonrası, 100 ppm/5 dk, erken kilit yeniden ortalama).

## Handoff

- **Commit:** (git log: `T-067: ...`)
- **Dokunulan dosyalar:** `AdaptivePacer.kt`, `client-android/app/src/test/.../video/LockRecenterTest.kt` (yeni), bu kart.
- **Varsayımlar:** Simülasyon (60 Hz, 60 fps, ready = cap + 16 ms + jitter 0-4 ms, %1 6-12 ms sıçrama, 6 faz) cihazdaki dakikalarca süren yanlış kilidi birebir üretmiyor; eski kodda yalnız boşluk/soğuk başlangıç sonrası ilk saniyede yanlış kilit görülüyor. Sayılar (eski -> yeni): boşluk sonrası ilk 1 sn geç kare, 6 faz ortalaması %6,4 -> %0,3 (soğuk başlangıç ilk 1 sn: %5,8; en kötü faz 15 ms: eski %31,7 soğuk / %35 boşluk sonrası -> yeni %15 soğuk, %0 boşluk sonrası). Soğuk 60 sn (ilk 2 sn sonrası) geç kare en fazla %0,5 (eski aynı; rephase 0-9). 100 ppm kayma 5 dk: geç kare %0,10-0,19, rephase 9-20 (eski 11-20, ~4/dk, aynı). Yeni testler eski kodda: `gapKeepsJitterHistory` kırmızı (%6,39 vs soğuk %5,83), `earlyLockIsRecentred...` eski kodda 18 geç kare / `recenters` yok.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Gerçek içerik (köşede her vsync renk değiştiren kare, 1 sn+ boşluktan sonra) 3 dk SurfaceFlinger 14 sn pencereleri: 33 ms boşluk oranı ilk pencerelerde belirgin düşük olmalı (önceki %17,5 / 26,2 / 11,5 ...), `ev=present` `late_drops` ve `rephase` sayıları. Gerekirse `recenters` loga eklenebilir (StatsFormat'a eklenmedi).
- **Açık sorular:** Cihazdaki kademeli (dakikalar süren) iyileşmenin asıl nedeni simülasyonda yeniden üretilemedi; cihaz ölçümü yetersizse ham `dev` dağılımı incelenmeli (taban/saat kayması şüphesi).
