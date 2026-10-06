---
id: T-270
title: Cihaz kabulü — Wi-Fi dosyaları (0035): bütçeli ölçüm + Codex --high
status: todo
phase: 6
owner: orchestrator
depends_on: [T-268, T-269]
decisions: [0035]
files:
  - docs/NOTES.md
  - backlog/tasks/T-270-wifi-files-device.md
---

## Amaç

Araştırma §2 bütçeleriyle (ölçümden önce yazılı): kontrol srtt p95 ≤ 45 ms; ses ≤ 1 kesilme / 5 dk; `skip_pct` dosyasız temelden en çok +1 puan; cap_dec p95 en çok +10 ms. Senaryolar: Wi-Fi'da aç → Finder'da `MateBridge/Wi-Fi` liste görünümü, küçük dosya kopyalama iki yön, büyük dosya (> 256 MB) kopyası sürerken kaydırma/video, çıkarma, Wi-Fi düşmesi, Mac uykusu, USB'ye geçiş. Kullanıcıyla, "test ediyorum" dediğinde.

## Handoff

## Open questions
