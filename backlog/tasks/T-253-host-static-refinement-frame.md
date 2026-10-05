---
id: T-253
title: Host — "refine when still": after motion stops, send one high-quality frame of the unchanged screen
status: ready
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0033]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - backlog/tasks/T-253-host-static-refinement-frame.md
---

## Amaç

Kullanıcı onayladı (2026-10-05): ekran durunca yazı/ikonlar netleşsin. Hareket sırasında bit hızı aynı kalır; hareket bitip ekran durağanlaşınca host son içeriği bir kez çok daha yüksek kalitede kodlar (Parsec/RDP "progressive refinement" benzeri). T-249: tablet çözücüsü 150 Mbps eşdeğeri büyük kareleri ~+2 ms ile çözüyor; IDR ~+15 ms. 4:4:4 çalışmasıyla (docs/research/2026-10-05-yuv444-packing.md §6 "yardımcı yalnız durağanken") ileride birleşebilir; bu kart yalnız 4:2:0 kalite iyileştirmesi.

## Bağlam

- **Önce tasarım (Plan bölümünde, kod öncesi commit):** SCK değişiklik yokken kare göndermiyor; durağanlık nasıl algılanır (son kareden beri T ms yeni kare yok; önerilen ~150–300 ms), hangi VT yolu yüksek kaliteli tek kare verir (geçici `Quality`/`AverageBitRate`/`DataRateLimits` değişimi + aynı pikselleri yeniden kodlama; ya da zorunlu IDR; VT'nin oturum içi özellik değişikliğinin gecikme/yan etkisi ölçülsün), son yakalanan `CVPixelBuffer`'ın güvenle tutulması (SCK havuz ömrü), sonraki normal karede bit hızının eski hale dönmesi, hız denetiminin (LLRC/fast profil, 120 fps'te `.fast`) bozulmaması.
- Kısıtlar: yeni kare sıradan bir kare olarak gider (tel biçimi DEĞİŞMEZ; istemci değişikliği gerekmemeli: yeni `frame_seq`, yeni zaman damgası). Hareket yeniden başlarsa iptal/önceliksiz. Boyut sınırı: tek kare için üst bayt sınırı; Wi-Fi'da (taşıma bilgisi host'ta varsa) daha küçük sınır ya da kapalı — patlama Wi-Fi'da ses/girdi gecikmesi yapıyordu (NOTES T-126). DISPLAY_RATE/boşta karartma (0031, T-234: karartma kare akışına bakıyor mu?) ve HDR (0032), keskin renk (0033) ile etkileşim incelensin.
- Düğme: `MATEBRIDGE_REFINE=0` kapatır; `MATEBRIDGE_REFINE_MS`, `MATEBRIDGE_REFINE_KB` ayarlar. Log: `ev=refine bytes= enc_ms= quality=`.
- Mac'te pencere açma; birim testleri durağanlık zamanlayıcısı ve karar mantığı için. Cihaz testi orkestratörde.

## Kabul kriterleri

- [ ] Plan (tasarım) önce commit; sonra uygulama.
- [ ] Durağanlıktan sonra tek yüksek kaliteli kare; hareket varken hiç; varsayılan açık ya da kapalı önerisi gerekçeli.
- [ ] Birim testleri; `./scripts/check.sh` geçer.
- [ ] Handoff: cihazda doğrulama (yazı netliği öncesi/sonrası, `ev=refine` boyutları, tablet `dec_*` ve gecikme, Wi-Fi'da ses kesintisi yok).

## Plan

## Handoff

## Open questions
