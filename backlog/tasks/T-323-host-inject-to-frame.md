---
id: T-323
title: Host — "girdi enjekte edildi → ilk değişen kare" süresi (EN2/HA3), SCK dirty rect ile; yalnız log
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-323-host-inject-to-frame.md
---

## Amaç

T-298 `docs/reviews/2026-10-08/agents/opt-c-e2e.md` EN2 ve `opt-a-host.md` HA3. Gecikme zincirinde "CGEvent gönderildi → uygulama çizdi → WindowServer → SCK geri çağrısı" segmenti kör, ve muhtemelen host'taki en büyük kalem.

## Kabul

1. Her basma kenarında (tuş basma, düğme basma, kalem teması başlangıcı) host monoton saatiyle damga alınır.
2. Damgadan sonraki ilk `complete` SCK geri çağrısında, boş olmayan dirty rect varsa gecikme ölçülür. İkinci aşama (varsa): enjeksiyon noktasını içeren ilk dirty rect.
3. Yeni olay `video ev=inject_to_frame n= p50_ms= p95_ms= max_ms=` 10 sn'de bir, yalnız örnek varken yazılır. Koordinat ya da içerik yok.
4. Ölçüm, ekran başka nedenle de değişiyorsa yanlış eşleşebilir. Bunun için "son 500 ms durağan pencere" koşulu ya da ayrı bir `noisy` sayacı (yaklaşık bir ölçü olduğu Handoff'ta belirtilir).
5. Saf eşleştirme mantığı Core'da test edilir. Host yolu derleme ve cihazla doğrulanır.
6. Önerilen LOGGING metni Handoff'a.

## Plan

## Handoff

## Open questions
