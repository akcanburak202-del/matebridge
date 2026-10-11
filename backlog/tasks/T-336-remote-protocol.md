---
id: T-336
title: Protokol — uzak profil (STREAM_PREFS link grubu, fps 15/30, bit hızı tabanı 500), AAC ses, uzaktan eşleşme yasağı
status: done
phase: 7
owner: orchestrator
depends_on: []
decisions: [0038]
files:
  - docs/decisions/0038-remote-low-data-mode.md
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - backlog/tasks/T-336-remote-protocol.md
---

## Amaç

Karar 0038'in tel biçimi: PROTOCOL.md §3 (uzaktan eşleşme yok), §4 HELLO bit14, STREAM_PREFS (fps 15/30, `500`–`150000`, bağlantı grubu `link`), CURSOR_STATE ve STATS uzak aralıkları, AUDIO_PREFS `codec`, AUDIO_CONFIG `format = 2`, AUDIO_FRAME `frame_count` 1–1024; §5 STARTUP geri çekilmesi; §6 uzak zamanlamalar.

## Handoff

- Fixture'lar: `stream_prefs_remote`, `invalid_stream_prefs_link_partial`, `audio_prefs_aac`, `audio_config_aac`, `audio_frame_aac`, `invalid_audio_frame_count`; `audio_prefs` alan adı `reserved` → `codec` (bayt aynı).
- Entegrasyon dalı `task/0038-remote-integration`. Bu daldaki `check.sh` yalnız "her fixture'ın testi var" denetiminde düşer; T-337 (Swift) ve T-339 (Kotlin) yeni fixture'ların testlerini ekler.
