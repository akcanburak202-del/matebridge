---
id: T-025
title: Faz 2 cihaz doğrulaması — Krita test matrisi, kalem gecikmesi, takılı girdi avı
status: todo
phase: 2
owner: orchestrator
depends_on: [T-023, T-024]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-025-phase2-device-validation.md
---

## Amaç

PLAN Aşama 2 "Bitti" ölçütünü kullanıcıyla doğrulamak.

## Kabul kriterleri

- [ ] Krita: basınçla kalınlaşan/incelen fırça, eğim (fırça destekliyorsa), hover imleci, silgi (M-Pencil'de varsa), çift dokunma eylemi.
- [ ] 15 dakikalık serbest çizim: kopuk çizgi yok, takılı kalan tık yok. Arada Wi-Fi kesme / uygulamayı arka plana alma / kablo çekme denemeleri → Mac'te hiçbir düğme basılı kalmaz.
- [ ] Avuç reddi: kalemle çizerken avuç ekrana değince çizgi bozulmaz.
- [ ] Dokunma: tek dokunuş tık, sürükleme, iki parmak kaydırma.
- [ ] T-022 incelemesinden gelen kontroller: uygulamayı arka plana alıp döndükten sonraki **ilk** dokunuş tık üretiyor (işaretçi kilidi, PROTOCOL §7); kalem ekranda kıpırdamadan dururken çizgi 100 ms'de bir bölünmüyor (canlılık tekrarı `STROKE_START` taşımıyor); parmakla sürüklerken kalem yaklaşınca imleç iki konum arasında zıplamıyor.
- [ ] Kalem gecikmesi: hover/uç ile imleç arasındaki fark (telefon slow-motion ya da log zaman damgaları); gerekirse tablette yerel imleç noktası kararı.
- [ ] Sonuç tablosu `docs/NOTES.md`'de; kullanıcının kullandığı tasarım uygulamaları varsa onlar da.

## Kullanıcı kararları — verildi (karar 0006, 2026-09-30): çift dokunma = fırça/silgi geçişi, çizimde parmak kapalı, yan tuş yok.

### Sorulan sorular

1. Kalemin çift dokunuşu ne yapsın? (ör. silgi/fırça geçişi — Krita'da `E` tuşu; geri al — Cmd+Z; sağ tık; hiçbir şey)
2. Parmakla dokunma: tık/sürükle olsun mu, yoksa çizim uygulamalarında yanlış dokunmayı önlemek için tamamen kapalı mı (ayar)?
3. Kalem yan tuşu (varsa) → sağ tık mı?

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
