---
id: T-242
title: Client — "Otomatik" bit rate picked inside Oyun/Çizim must mean the layer default (60 Mbps), not the host formula
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0014, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-242-client-auto-bitrate-in-mode-layer.md
---

## Amaç

Cihaz 2026-10-05: kullanıcı Oyun modundayken panelden bit hızını "Otomatik"e aldı → host 20 Mbps uyguladı (`ev=profile fps=60 bitrate_kbps=20000 bitrate_source=prefs display=2240x1472@1x dynamic_range=hdr10`). Neden: `GameModeSettings.defaults()` kayıtlı değer Otomatik iken katmana `GAME_BITRATE_KBPS` (60 Mbps) koyuyor, ama katman açıkken `setBitrateKbps(0)` `write()` ile katmanın kopyasını 0'a çeviriyor; STREAM_PREFS 0 gider, host modun formülünü uygular (2240@60 → 19,2 → alt sınır 20 Mbps). Oyun moduna Otomatik'le girince 60, içerideyken Otomatik seçince 20: tutarsız.

## Kabul kriterleri

- [ ] [JVM] Oyun ve Çizim katmanı açıkken Otomatik seçilirse etkin bit hızı katman varsayılanı (`GAME_BITRATE_KBPS`) olur; STREAM_PREFS'te 60000 gider. Günlük'te Otomatik bugünkü gibi 0 (host formülü).
- [ ] [JVM] Panel etiketi katman açıkken "Otomatik (60 Mbps)"; seçili işaret Otomatik'te kalır.
- [ ] [JVM] Kalıcı (kaydedilen) değer kuralı değişmez (0014 §3 yazma kuralı).
- [ ] `./scripts/check.sh` geçer.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
