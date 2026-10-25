---
id: T-377
title: Tasarım incelemesi — gpt-6-astra (high), Wi-Fi'da oyun: anlık kötüleşmede takılmadan geçiş ve toparlanma
status: in_progress
phase: 7
owner: orchestrator
depends_on: [T-327, T-328, T-369, T-370, T-371]
decisions: [0023, 0016, 0029]
files:
  - docs/reviews/
  - backlog/tasks/T-377-astra-wifi-game-stalls.md
---

## Amaç

Kullanıcı onayı (2026-10-25): Codex `gpt-6-astra`, salt okunur, Wi-Fi (yerel ağ) üzerinden oyunu "kusursuz" yapmak için kalan iyileştirmeler. Dar soru: WLAN anlık kötüleştiğinde (yeniden gönderim, srtt sıçraması) takılma (>150 ms) yerine kısa kalite düşüşü, ve kayıptan sonra hızlı toparlanma. `MATEBRIDGE_WIFI_ADAPT` yeniden tasarımı (2026-10-23 cihaz denemesi başarısız), T-372 (IDR arkasında delta tutma), T-373 (LTR).

## Kabul

1. `codex exec -m gpt-6-astra -s read-only -c 'model_reasoning_effort="high"' -o <scratch>/astra-out.md`, istem scratch `astra-wifi-prompt.txt`.
2. Çıktı aynen `docs/reviews/2026-10-25/astra-wifi-game.md`, üstüne orkestratör triyajı (öneri → kanıt, risk, ölçüm yolu).
3. Kod yazılmaz. Gerçek ve değerli öneriler için kart taslakları; karar gerekenler kullanıcıya.
4. Onay yalnız bu çalıştırmayı kapsar (başarısızsa bir kez yeniden).

## Plan

## Handoff

## Open questions
