---
id: T-080
title: Tablet — sabit oynatma gecikmeli zamanlayıcı (düzensiz içerikte 120 Hz boşluklarını azalt), anahtar arkasında
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-071, T-077]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - tools/pacing/
  - backlog/tasks/T-080-client-constant-playout-pacer.md
---

## Amaç

İz analizi (NOTES 2026-10-01 ~14:45). 60 Hz'te bugünkü faz kilidi kusursuz (trace6/trace8: planlanan boşluk %0,02–0,04, hazır→slot 13–16 ms). Ama **120 Hz + düzensiz içerik** (kullanıcı çiziyor, Mac pencereyi fare olay hızında ~110–117/sn günceller; yakalamalar düzenli 8,33 ms değil) — trace7, Akıcı mod: kilit %2,4 planlanan boşluk @ 13,1 ms; geç sayılan karelerin payı p90 **+60 ms** (kilit tahmini kayıyor, kareler "çok erken" diye atılıyor). Simülasyon (`tools/pacing/sim.py`, aynı iz) **sabit oynatma gecikmesi** politikasıyla: q=0,9 → 13,3 ms / %1,1; q=0,95 → 18,1 ms / %0,5; q=0,99 → 20,4 ms / %0,2.

Politika (sim.py ile birebir): x = ready − capture; taban b = son 256 karenin min(x)'i; J = (x − b)'nin q yüzdeliği; C = b + J, **2 ms histerezis** (yeni değer eskisinden > 2 ms farklıysa güncellenir); hedef t = capture + C + L (L = etkin son an, 6 ms); slot = ızgarada t'den sonraki ilk vsync, ama ready + L'den önce olamaz. Aynı slota düşen iki kare: yenisi kazanır (T-065 releaser değişmezi korunur: en yeni kare her zaman gösterilir). "Çok erken" diye atma **yok**.

## Kabul kriterleri

- [ ] `--es pacer cpd` (sabit oynatma) | `lock` (bugünkü, varsayılan); `--ei cpd_q_permille N` (varsayılan 950), `--ei cpd_hold_us N` (varsayılan 2000). `ev=display_timing` satırında etkin değerler.
- [ ] CPD yolu her panel hızında çalışır (60/120), epoch değişiminde sıfırlanır, uzun boşluktan sonra (> 1 s) C korunur ama taban penceresi yeniden dolar (gerekçelendir). Seyrek kareler (T-065 testleri) CPD'de de kayıpsız.
- [ ] **Çevrimdışı eşdeğerlik testi:** `tools/pacing/trace7_120hz_excerpt.csv` (3000 kare, yalnız zaman sütunları) test kaynağına kopyalanır/okunur; Kotlin CPD uygulaması bu izi oynatınca planlanan boşluk ve gecikme p50, `sim.py`'nin aynı parametrelerle verdiği değerlere ±0,2 puan / ±0,5 ms içinde eşit. Sim değerlerini karta yaz.
- [ ] İz (`pace_trace`) CPD kararlarını da yazar (`path=cpd`).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
