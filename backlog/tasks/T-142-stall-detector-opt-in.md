---
id: T-142
title: Ses takılma dedektörünü (mb-stall) açılış parametresine bağla, varsayılan kapalı
status: done
phase: 5
owner: android-client-dev
depends_on: [T-120, T-141]
decisions: []
files:
  - client-android/app/src/
  - backlog/tasks/T-142-stall-detector-opt-in.md
---

## Amaç

T-120'nin `StallDetector`'ı (`diag/StallDetector.kt`, `SessionController` içinde) oturum boyunca URGENT_AUDIO önceliğiyle 5 ms'de bir uyanıyor (200/s) ve saniyede bir `diag ev=stall_stats` yazıyor. T-141 sonrası durgun ekranda istemcinin kalan ~%9 CPU'sunun ~%1,5'i bu (docs/NOTES.md 2026-10-02 ~23:40). Ses takılması araştırması bitti (T-121/T-122). Teşhis gerektiğinde açılabilsin, varsayılanda hiç çalışmasın. Kullanıcı onayladı (2026-10-02).

## Kapsam dışı

- Dedektörün mantığı ve eşikleri, ses yolu, diğer teşhis satırları.

## Kabul kriterleri

- [ ] `--ez stall_diag true` açılış parametresiyle dedektör bugünkü gibi çalışır (iş parçacığı, öncelik, `ev=stall_stats` ve olay satırları aynı).
- [ ] Parametre yoksa `mb-stall` iş parçacığı hiç başlatılmaz, `stall_*` satırı yazılmaz. Dedektörün beslendiği diğer kodlar (okuyucu arayüzleri, sayaçlar) dedektör yokken hata vermez ve boşa iş yapmaz.
- [ ] Açılışta bir kez `diag ev=stall_diag enabled=0|1`.
- [ ] `docs/LOGGING.md`'de değişiklik gerekiyorsa *Açık sorular*a yaz (orkestratör yapar).
- [ ] JVM testi ya da mevcut testlerin güncellenmesi: kapalıyken başlatılmadığı, açıkken başlatıldığı.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

`StallDiag.create(enabled, readers)` (diag/) dedektörü yalnızca açıkken üretir; `SessionController` `stallDiag` parametresiyle nullable `stallDetector` tutar (`?.start/stop`); `lastControlReadNs` yazımı ve gap satırındaki `tick_late_ms` kapalıyken atlanır (`-`). `MainActivity` `--ez stall_diag` okur, açılışta `diag ev=stall_diag enabled=0|1` yazar. Test: `StallDiagTest`.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:** bkz. git log task/T-142-stall-opt-in
- **Dokunulan dosyalar:** MainActivity.kt, session/SessionController.kt, diag/StallDiag.kt (yeni), test diag/StallDiagTest.kt, bu kart
- **Varsayımlar:** `lastVideoReadNs` T-117 ses gap satırı için de kullanıldığından olduğu gibi bırakıldı. Audio gap satırında dedektör yokken `tick_late_ms=-`.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Parametresiz açılışta logda `diag ev=stall_diag enabled=0`, `mb-stall` iş parçacığı yok, `stall_stats` yok; `--ez stall_diag true` ile `enabled=1`, `stall_detector_start` ve saniyelik `stall_stats` var.
- **Açık sorular:** docs/LOGGING.md'ye `diag ev=stall_diag enabled=` satırı eklenmeli, stall_* satırlarının `--ez stall_diag true` gerektiği yazılmalı (orkestratör).
