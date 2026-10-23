---
id: T-365
title: Host — FrameGate geç kareden sonra yeniden demirlenince zamanında gelen kareleri dakikalarca bekletiyor
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-365-frame-gate-reanchor.md
---

## Amaç

Kanıt: NOTES 2026-10-23 öğleden sonra ("30 Mbps neden kötü göründü"). Oyun 60'ta host `ev=latency` `gate_wait` p50 bir aksaklıktan sonra (kodlayıcı yeniden başlaması, ~32 ms yazma takılması) 0,1 → 8–10 ms'ye sıçrıyor ve ~0,04 ms/s ile eriyerek dakikalarca yüksek kalıyor. `slot_wait` ve `gpu` 0; fark tamamen kapı beklemesi. Bu, bütün modlarda rastgele 0–10 ms fazladan host gecikmesi demek.

Çıkarım (kodla uyumlu, doğrulanacak): `FrameGate.accept` bir kare yuvadan bir aralıktan fazla geç gelince ızgarayı `now + interval`'a demirliyor. Geç kalan kare, kaynak (SCK, sanal ekran vsync'i) kadansına göre geçse, sonraki zamanında gelen kareler yeni yuvadan `geçlik` kadar erken kalıyor; `passThroughToleranceUs` (yarım aralık) bunu karşılamayınca her kare `geçlik − tolerans` kadar bekletiliyor. Izgara her kabulde yalnız bir aralık ilerlediği için ofset ancak sanal ekran saati ile host saati arasındaki kayma hızında eriyor.

## Kabul

1. **Önce kırmızı test** (`FrameGate`/`FramePacer` seviyesinde, saf): 60 fps, kaynak periyodu sabit (ör. 16 667 µs ± küçük kayma) varışlar; araya bir kare 20–30 ms geç girer (sonrakiler eski kadansa döner). Beklenti: geç kareden sonra en geç birkaç kare içinde (kart sayıyı Plan'da belirler) her karenin kapı beklemesi ≤ 1 ms. Bugünkü kodda test kırmızı olmalı (Handoff'ta kırmızı çıktı).
2. Düzeltme kapının amacını korur: uzun dönem gönderim hızı stream fps'i aşmaz; bir aralık içinde en fazla iki kare geçer (T-072 kuralı); decimation kipi (T-058, `setTargetFps` < stream fps) davranışı değişmez; T-065/T-066 kuralı (bir kare yalnız daha yenisi onun yerini alınca düşer) bozulmaz.
3. Mevcut FrameGate/FramePacer testleri geçer; değişen beklentiler Handoff'ta listelenir.
4. Ek testler: kalıcı faz kayması (kaynak saati host saatinden ±50 ppm), idle sonrası yeniden demirleme, burst (iki kare arka arkaya) — hız sınırı korunuyor.
5. LOGGING.md'de `gate_wait` açıklamasına bir cümle (gerekirse).
6. `./scripts/check.sh` geçer.

## Plan

(ajan doldurur)

## Handoff

## Open questions
