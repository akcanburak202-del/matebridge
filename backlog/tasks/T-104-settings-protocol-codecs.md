---
id: T-104
title: Ayarlar paneli protokolü kod çözücüleri (Swift + Kotlin) — STREAM_PREFS.bitrate_kbps, SETTINGS_OPEN (0x08), HELLO bit9
status: todo
phase: 4
owner: mac-host-dev
depends_on: []
decisions: [0013]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/test/
  - backlog/tasks/T-104-settings-protocol-codecs.md
---

## Amaç

Karar 0013 protokolü değiştirdi. Orkestratör `docs/PROTOCOL.md` ve `protocol/fixtures/` dosyalarını bu dalda (`task/T-104-settings-protocol`) güncelledi:
- `STREAM_PREFS` alanı: `reserved u32` → `bitrate_kbps u32`;
- yeni mesaj `0x08 SETTINGS_OPEN` (H→C);
- HELLO `capabilities` bit9 `SETTINGS_PANEL`;
- fixture'lar: `stream_prefs_bitrate`, `settings_open`.

Burada yalnızca iki tarafın kod çözücüleri ve fixture testleri yapılır. Davranış T-105 (tablet) ve T-106 (host) kartlarında.

## Kabul kriterleri

- [ ] Swift ve Kotlin `StreamPrefs` tiplerine `bitrateKbps` (u32, varsayılan 0) eklenir; encode/decode PROTOCOL.md ile birebir. Bugün bu alanı gönderen kod `0` gönderir (davranış değişmez).
- [ ] `SettingsOpen` mesajı (0x08, `reserved u32`) iki tarafta encode/decode:
  - Swift'te gönderim için encode API;
  - Kotlin'de decode edilip üst katmana olay olarak iletilir ya da şimdilik yok sayılır (davranış T-105'te).
  - Kısa payload protokol hatası, fazlası yok sayılır (§2).
- [ ] `Capabilities` bit9 `SETTINGS_PANEL` sabiti iki tarafta. Kotlin istemci bu biti **henüz göndermez** (T-105'te açılır).
- [ ] Swift `SessionMachine` (ya da eşdeğeri) exhaustive switch'lerde yeni case'i ele alır. Yanlış yönden gelen `SETTINGS_OPEN` yok sayılır.
- [ ] Fixture testleri: `stream_prefs`, `stream_prefs_bitrate`, `settings_open` iki tarafta kapsanır. "Her fixture'ın testi var" testleri geçer.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff
