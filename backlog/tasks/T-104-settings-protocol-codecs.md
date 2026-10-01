---
id: T-104
title: Ayarlar paneli protokolü kod çözücüleri (Swift + Kotlin) — STREAM_PREFS.bitrate_kbps, SETTINGS_OPEN (0x08), HELLO bit9
status: in-progress
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

**Swift (`host-mac/Sources/MateBridgeCore/`):**
1. `ProtocolConstants.swift`: `MessageType.settingsOpen = 0x08`.
2. `Messages.swift`:
   - `StreamPrefs.bitrateKbps: UInt32`, init parametresi varsayılan `0` (mevcut çağrılar derlenir, `0` gönderir). `write`/`read` u32'yi yazar/okur.
   - `normalized` bit hızını ham değeriyle korur; sıkıştırma (5000–150000) ve uygulama T-106'da.
   - Yeni `SettingsOpen` (reserved u32; encode 0 yazar, decode atlar).
   - `Capabilities.settingsPanel = 1 << 9`.
3. `Message.swift`: `case settingsOpen(SettingsOpen)`; `type`, `encodePayload`, `decode` güncellenir. Encode API: `Message.settingsOpen(SettingsOpen()).encode()` / mevcut `sealed` yolu.
4. `Session/SessionMachine.swift` `handleCommon`: `.settingsOpen` yanlış yön (C→H geldi) listesine eklenir → yok sayılır. `Input/InputStateMachine.swift` exhaustive switch'ine `.settingsOpen` eklenir (no-op).
   - `MateBridgeHost` `default:` kullanıyor; dokunulmaz.
5. Testler (`host-mac/Tests/`):
   - `FixtureTests`: `stream_prefs` (bitrate 0), `stream_prefs_bitrate` (40000), `settings_open`.
   - `CodecTests`: STREAM_PREFS/SETTINGS_OPEN kısa payload hata, fazla bayt yok sayılır; capability bit9 değeri.
   - `SessionMachine` testi: istemciden gelen `SETTINGS_OPEN` aktif oturumda yok sayılır (deliver yok, oturum sürer).

**Kotlin (`client-android/.../protocol/`):**
1. `Messages.kt`: `MsgType.SETTINGS_OPEN = 0x08`; `StreamPrefs(fps, scalePermille, bitrateKbps: Long = 0)`; `object SettingsOpen : Message` (veri yok; reserved modellenmez); `Capabilities.SETTINGS_PANEL = 1 shl 9` (istemci henüz göndermez, `MainActivity` değişmez).
2. `Codec.kt`: encode/decode `bitrate_kbps` u32 ve `SETTINGS_OPEN`.
3. Üst katman: `session/SessionMachine.onMessage` zaten `else -> Unit` ile yok sayıyor (dosya kart kapsamı dışında, değişmez); davranış T-105'te.
4. Testler (`client-android/app/src/test/`): `FixtureTest` üç fixture; `CodecRulesTest` kısa payload listesine `STREAM_PREFS`, `DISPLAY_RATE`, `SETTINGS_OPEN`, fazla bayt yok sayılır, bit9 değeri.

**Doğrulama:** `./scripts/check.sh`.

## Handoff
