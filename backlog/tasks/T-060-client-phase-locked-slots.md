---
id: T-060
title: Tablet — akış hızı panel hızına eşitken faz kilitli yuva ataması (histerezis); seyreltmeyle 33 ms boşlukları gider
status: review
phase: 5
owner: android-client-dev
depends_on: [T-057, T-059]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/
  - backlog/tasks/T-060-client-phase-locked-slots.md
---

## Amaç

T-058/T-059 cihaz ölçümü (2026-10-01 ~03:30, dal `integ/rate` = main + T-058 + T-059): panel 60 Hz'teyken host seyreltip 60 fps gönderiyor (`cap_fps=120 enc_fps=60 sent_fps=60`, varış 8,3→16,7 ms düzenli). İlk ölçüm iyi (33 ms boşluk %2,3), ama 120→60 geçişinden sonraki ikinci ölçümde **%25,6** 33 ms boşluk: tablet `recv=61 shown=50`, `slot_dups=10 late_drops=10`, `d_us=24999` (1,5 P). Neden: akış hızı panel hızına eşitken her kare zamanı ayrı ayrı en yakın vsync'e yuvarlanıyor; varış fazı yuva sınırına yakınsa titreşim kareleri iki yuva arasında zıplatıyor → aynı yuvaya iki kare + boş yuva. Faza bağlı olduğu için bazen iyi bazen kötü.

## Kabul kriterleri

- [ ] **Faz kilidi:** kare aralığı ≈ panel periyodu (±%15) iken yuva ataması kare sırasına göre: `slot(n) = slot(n−1) + round(Δcapture / P)` (normalde +1); yuvanın gerçek varış zamanına göre hatası izlenir ve yalnızca hata belirli bir süre (ör. 0,5 sn ya da 30 kare) boyunca yarım periyottan büyük kalırsa yeniden fazlanır (histerezis). Tek bir geç kare kilidi bozmaz: o kare ya zamanında sığar ya atılır (en yeni kazanır), sonraki kareler kilide göre devam eder.
- [ ] Kilitli moddaki `D` ölçülen jitter'a göre ama en çok 1 P; kilit fazı, jitter'ın en kötü durumunu yuva içinde tutacak şekilde (varış dağılımının ortası yuva ortasına) seçilir.
- [ ] 120 fps akış/60 Hz panel (seyreltme yokken) ve 120/120 davranışı gerilemez (T-057 sonuçları).
- [ ] İstatistik: `phase_lock=1/0`, `rephase` sayacı.
- [ ] Testler: 60/60 ve 120/120'de varış fazı yuva sınırında ±1 ms titreşimle → neredeyse sıfır çift/boş yuva; yavaş saat kayması (ör. 60,00 vs 59,95 Hz) → seyrek, tek seferlik yeniden fazlanma; geçişler (120↔60). `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Host. Cihaz ölçümü orkestratörde (`pace-long.sh`, 60 Hz boşta birkaç tur + 120 Hz).

## Plan

Yalnızca `AdaptivePacer` (+ istatistik alanları) değişir; SlotReleaser/VsyncClock dokunulmaz.

1. **Kilit koşulu:** etkin aralık `fi` (intervalProvider) panel periyodu P'nin ±%15'inde ve seyreltme yok (`fi*4 >= P*3`). Değilse kilit bırakılır, eski yol (T-057) aynen çalışır.
2. **Edinme:** jitter'sız ideal hazır zamanı `T = now - dev` (= capture + b). Pencere `[T+dl, T+dl+j]` (j = p99 dev). Merkezli hedef `sC = T+dl+j/2+P/2`, asgari `sMin = T+dl+d` (d = min(p99+margin+extra, P)). Yuva = `sC`'ye en yakın vsync, ama `sMin`'den önce olamaz ve `earliest`'ten önce olamaz.
3. **Kilitli ilerleme:** `slot(n) = snap(slot(n-1) + round(Δcapture/P)·P)` (gerçek vsync ızgarasına yuvarlanır). Hata `e = sC - slot`, jitter'sız `T` ile ölçülür, tek geç kare onu bozmaz. Kare yuvasına yetişemezse (`slot < earliest`) o kare atılır (önceki yuvaya çarpıştırılır, `lateDrop`), kilit ilerler.
4. **Histerezis:** `|e| > P/2` ya da kaçırılan yuva art arda 30 kare sürerse yeniden fazlar (`rephase++`, edinme yolu); tek iyi kare sayacı sıfırlar.
5. **İstatistik:** `phase_lock=1/0`, `rephase=<pencere>` `ev=present` satırına (StatsFormat.presentFields genişler).
6. **Testler:** 60/60 ve 120/120 sınır fazında ±1 ms jitter (çift/boş yuva ~0), 60,00 vs 59,95 Hz kayması (seyrek yeniden fazlama), 120↔60 geçişleri, tek geç kare, eski T-057 testleri.

## Handoff

- **Commit:** bu commit (SHA orkestratöre raporlandı)
- **Dokunulan dosyalar:** `video/AdaptivePacer.kt` (faz kilidi, `scheduleLocked`), `video/VideoRenderer.kt` (istatistik), `stream/StatsFormat.kt` (`phase_lock`, `rephase`), testler `PhaseLockTest.kt` (yeni) ve `PresentationSchedulingTest.kt` (format). `StatsFormat.kt` kartın `files:` listesinde yok; tek satırlık istatistik alanı için gerekliydi.
- **Varsayımlar:** Kilit yalnızca `|fi - P| <= %15 P` iken (seyreltme sonrası 60/60, 120/120); `fi` T-059 `intervalProvider`'dan gelir. Kilit fazı: varış penceresi `[ideal, ideal+p99]` yuvanın ortasına (en yakın vsync), ama `ideal + D`'den ve `earliest`'ten önce olmaz. Yeniden fazlama: taze edinme başka bir yuva seçerse (hata > P/2, ya da en kötü jitter/kare yuvayı kaçırır) art arda 30 kare sürerse; `rephase` pencere başına delta. Kilitte gecikme sınırı `earliest + P + min(jitter,P)/2`; aşan ya da yuvasına yetişemeyen kare önceki yuvaya çarpıştırılır (`lateDrop`), kilit ilerler. Kilitli D en çok 1 P. `rephases` panel epoch sıfırlamasında sıfırlanır.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `check.sh` geçti. Cihazda: 60 Hz boşta birkaç `pace-long.sh` turu, 33 ms boşluk oranı (ikinci turda %25'e çıkmamalı), `ev=present` satırında `phase_lock=1`, `rephase` 0 ya da seyrek, `slot_dups`/`late_drops` düşük; 120 Hz'te T-057 sonuçları gerilememeli; 120<->60 geçişinde `phase_lock` yeniden 1 olmalı. Merkezli faz gecikmeyi en kötü ~P/2 artırabilir (`pace_ms`, `d_us`).
- **Açık sorular:** Merkezli faz 60 Hz'te gecikmeyi artırırsa `centered` yerine `minimum`'a yaslamak tek satırlık ayar.
