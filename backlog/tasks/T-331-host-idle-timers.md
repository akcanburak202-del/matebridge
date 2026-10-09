---
id: T-331
title: Host — oturum tiki yalnız bağlantı varken, refine zamanlayıcısı olay güdümlü (boş uyanmaları azalt)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-330]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Tests/
  - backlog/tasks/T-331-host-idle-timers.md
---

## Amaç

`docs/research/2026-10-10-optimization.md` A2 + A3.

- `SessionServer` 100 ms tiki bağlantı yokken de dönüyor. Boştaki ~10 uyanma/s bundan geliyor.
- `HEVCEncoder` refine zamanlayıcısı (25 ms) oturum boyunca sürekli dönüyor: 40 uyanma/s.

## Kapsam

1. **Oturum tiki:**
   - Bağlantı (ya da tcpInfo örnekleyicisi) yokken iptal edilir.
   - Bağlantı kabul yolunda, **durum oluşturulmadan önce** yeniden kurulur.
   - Hello, lookup, proving ve orphan son tarihleri eskisi gibi tetiklenir.
   - WoL uzlaştırması kendi 60 sn zamanlayıcısına taşınır.
2. **Refine:**
   - Zamanlayıcı yalnız hareketli kare geldiğinde kurulur. Tren bitince ya da hareketsizlik eşiği aşılınca kapanır.
   - Keyframe beklenmiyorsa idle tik 500 ms olur.
   - `keyframeDue` korumasına dokunulmaz.
3. Davranış aynı kalır. Refine treninin başlangıcı en fazla bir periyot kayabilir.

## Kabul

- Birim testleri şunları doğrular:
  - bağlantı varken son tarihler tetiklenir;
  - boşta zamanlayıcı çalışmaz;
  - refine treni hâlâ başlar.
- `./scripts/check.sh` geçer.
- Cihaz testi (orkestratör):
  - bağlantısız 5 dk `top -stats idlew`, eski ve yeni sürüm karşılaştırması;
  - bağlıyken, sabit ekranda aynı ölçüm;
  - kalem darbesinden sonra `video ev=refine` görülmeli.

## Plan

## Handoff

## Open questions
