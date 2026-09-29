---
id: T-014
title: Mac entegrasyonu — oturum + görüntü hattı, istatistik, uçtan uca akış
status: todo
phase: 1
owner: mac-host-dev
depends_on: [T-010, T-011]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/
---

## Amaç

Onaylanan oturumda sanal ekranı açıp kareleri video bağlantısına akıtmak. Oturum bitince sanal ekranı kapatmak (kısa kopmalarda bekleme süresiyle, NOTES 2026-09-29).

## Kabul kriterleri

- [ ] ACCEPTED → sanal ekran (tabletin `HELLO` çözünürlüğü) → `STREAM_CONFIG` → video akışı. `KEYFRAME_REQUEST` kodlayıcıya iletilir.
- [ ] Kopmada sanal ekran **10 sn** bekler; aynı cihaz geri gelirse aynı ekran kullanılır, gelmezse kapanır.
- [ ] `STATS` alınır: menüde ve `host.log`'da FPS, bitrate, gecikme.
- [ ] Soket yetişemezse video kuyruğu kuralı (§5) uygulanır. Bellek şişmez.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
