---
id: T-321
title: 144 Hz (Yüksek) ekran ayarında tabletin ağ trafiği duruyor; MateBridge ve adb kopuyor — sistem mi, MateBridge yükü mü
status: todo
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-321-144hz-wifi-stall.md
---

## Amaç

2026-10-08 ~19:12. Ayrıntı: `docs/research/2026-10-08-ddr-clock.md`, Ek 2. Kullanıcı ekran yenileme hızını "Yüksek (144 Hz)" yapınca:
- MateBridge bağlantısı tekrar tekrar koptu;
- adb (Wi-Fi) "offline" oldu;
- Wi-Fi sinyali mükemmel göründü.

60 Hz'e dönünce düzeldi.

## Yöntem

1. MateBridge kapalı, 144 Hz: Mac'ten tablete 60 sn `ping -i 0.2`; ayrıca adb kabuk yankısı.
2. MateBridge açık, 144 Hz, durağan ekran ve hareket sahnesi: aynısı, artı tablet iş parçacığı yükü. Okunabiliyorsa `dumpsys SurfaceFlinger` ve vsync oranı.
3. Kayıp 1'de varsa: sistem / Wi-Fi sorunu → kullanıcıya not; MateBridge 144 Hz isteğini sınırlamayı değerlendir. Yalnız 2'de varsa: MateBridge'in 144 Hz yolu (zamanlayıcı, vsync geri çağrıları, `setFrameRate`) incelenir.

## Plan

## Handoff

## Open questions
