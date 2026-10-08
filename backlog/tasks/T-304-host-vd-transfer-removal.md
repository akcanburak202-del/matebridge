---
id: T-304
title: Host — MATEBRIDGE_VD_TRANSFER anahtarını kaldır (karar 0032 eki); HDR10 aktarım ve primer kurulumu kalır
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-302]
decisions: [0032]
files:
  - host-mac/Sources/MateBridgeHost/Video/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-304-host-vd-transfer-removal.md
---

## Amaç

Karar 0032 eki, 2026-10-08 (`docs/reviews/2026-10-08/agents/simp-f-knobs.md`, VD_TRANSFER satırı).

## Kabul

1. **Kaldırılanlar:** `vdTransferKnob` ve SDR akışta tf=1 ekranı kurma ya da yeniden kullanma durumu. HDR10 akışında aktarım işlevi ve P3 primer kurulumu (T-237/T-281) aynen kalır; `MATEBRIDGE_VD_PRIMARIES` kalır.
2. **Özel API:** `VirtualDisplay` tek özel API dosyası olmaya devam eder; başka dosya `CGVirtualDisplay`'e dokunmaz.
3. **Log:** `ev=vd_transfer` alanları HDR10 için anlamlı kalır; `requested` artık yalnız akıştan gelir.
4. **Test ve derleme:** testler ve derleme geçer. Cihazda bakılacak (orkestratör): Günlük'te SDR ve HDR açılışı, `vd_transfer applied` değerleri.

## Plan

## Handoff

## Open questions
