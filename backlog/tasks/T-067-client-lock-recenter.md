---
id: T-067
title: Tablet — faz kilidi geç kare oranına göre yeniden ortalanır; boşta kalınca jitter geçmişi silinmez
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**

## Orkestratör notu (2026-10-01 ~09:55): cihazda geri alındı

Merge (566bf15) → cihaz, aynı köşe karesi içeriği, 12 × 14 sn: 33 ms+ boşluk **%24–41** (önce %1,4–26, kademeli düzelme), `late_drops` toplam 4512 / 170 sn (~26/sn), `rephase` 133. Giriş jitter'ı iki koşuda benzer (`ready_p99` pencere medyanı 25 / 23 ms). Geri alındı (48a9e2b). Şüphe: geç kare tanımı `presentationDeadline` = 13,33 ms kullanıyor (gerçek mandal ~6 ms, T-061) → oran tabanlı yeniden ortalama sürekli tetikleniyor. Önce T-068 (son an deney düğmesi) ölçülecek.
