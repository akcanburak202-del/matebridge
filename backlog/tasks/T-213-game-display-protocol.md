---
id: T-213
title: STREAM_PREFS optional game display group: codecs and fixture tests (Swift + Kotlin)
status: todo
phase: 6
owner: orchestrator
depends_on: []
decisions: [0029]
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/gen.py
  - protocol/fixtures/stream_prefs_game_display.hex
  - protocol/fixtures/invalid_stream_prefs_partial.hex
  - protocol/fixtures/stream_config_game_display.hex
  - host-mac/Sources/MateBridgeCore/Messages.swift
  - host-mac/Sources/MateBridgeCore/ByteIO.swift   # only if a remaining-bytes helper is missing
  - host-mac/Tests/MateBridgeCoreTests/FixtureTests.swift
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Messages.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Codec.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/protocol/FixtureTest.kt
  - backlog/tasks/T-213-game-display-protocol.md
---

## Amaç

Karar 0029 (oyun ekranı) için tel biçimi: `STREAM_PREFS`'in sonuna isteğe bağlı `display_width_px`/`display_height_px` (u16, yoksa 0) grubu. PROTOCOL metni (§2 "İsteğe bağlı sondaki grup", §0x05 tablo ve host kuralları, §0x03 metni) ve üç fixture (`stream_prefs_game_display`, `invalid_stream_prefs_partial`, `stream_config_game_display`) orkestratör tarafından bu dalda yazıldı. Bu kart iki codec'i ve fixture testlerini ekler. Davranış değişmez: iki taraf da ekranı varsayılan 0×0 bırakır.

## Bağlam

- Swift: `StreamPrefs` (`Messages.swift` ~:350-383) `displayWidthPx`/`displayHeightPx` (varsayılan 0); `read` grubu yalnız kalan bayt varsa okur, 1–3 bayt kalırsa `payloadTooShort(0x05)`; `write` 0×0 ise grubu yazmaz. `normalized` alanları geçirir (doğrulama host politikasında, T-214).
- Kotlin: aynı alanlar `Messages.kt` ~:159, `Codec.kt` encode ~:183 / decode ~:308 (`r.remaining()`).
- İki taraftaki fixture testleri kapsanmayan `.hex`'te başarısız olur (`FixtureTests.swift` ~:111, `FixtureTest.kt` ~:130): üç yeni fixture eklenmeli; `invalid_stream_prefs_partial` geçersizler kümesine.

## Kabul kriterleri

- [ ] [XCTest][JVM] 8 baytlık payload → ekran 0×0; 12 bayt → değerler; 10 bayt → reddedilir (iki taraf).
- [ ] [XCTest][JVM] 0×0 ile encode 8 bayt; sıfır olmayan 12 bayt; üç yeni fixture bayt bayt eşleşir; eski fixture'lar değişmez.
- [ ] [check] `gen.py --check` ve `./scripts/check.sh` yeşil.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
