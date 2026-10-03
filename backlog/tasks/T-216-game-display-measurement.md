---
id: T-216
title: Device measurement: game display sizes vs native (decision 0029)
status: todo
phase: 6
owner: orchestrator
depends_on: [T-214, T-215]
decisions: [0029]
files:
  - docs/NOTES.md
  - backlog/tasks/T-216-game-display-measurement.md
---

## Amaç

0029'un faydasını ve risklerini cihazda ölçmek. Kod yok.

## Kabul kriterleri

- [ ] [device] Her boyut × Oyun 120 / Oyun 60: uygulanan kip, `mode_selected`, SCK boyutu ve `cap_int`, çözme p50/p95, yakalama→gösterim p50, `skip_pct`, Mac CPU/GPU; `--ez dev true --ei game_display 0` ile karşılaştırma.
- [ ] [device] Giriş/çıkış yeniden kurulum süresi ve siyah süre, pencere davranışı, Krita; oyunun çözünürlük listesinde seçilen boyut görünüyor.
- [ ] [device] Kalem köşe ve merkezde, basınç ve eğim, dokunma, pinch, trackpad, fare hissi; `decoder_give_up` yok, takılı girdi yok.
- [ ] [device] Oyun modunda yeniden bağlanma ve bekletme/geri alma ekranı yeniden kullanıyor; `game_display_failed` hiç çıkmıyor (çıkarsa nedeni).
- [ ] [doc] Sonuç tablosu `docs/NOTES.md`'de; varsayılan boyut için öneri.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
