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

1. Swift `StreamPrefs`: `displayWidthPx`/`displayHeightPx` (varsayılan 0); `read` kalan bayt > 0 ise iki u16 okur (1–3 bayt → `payloadTooShort(0x05)`, mevcut `ByteReader.remaining` yeterli, `ByteIO.swift` değişmedi); `write` ikisinden biri ≠0 ise yazar; `normalized` geçirir.
2. Kotlin `StreamPrefs` aynı alanlar (`Int`, varsayılan 0); `Codec` encode/decode aynı kural (`r.remaining()`).
3. Üç fixture iki fixture testine; kural testleri (8/12/9–11/fazla bayt, tek alan ≠0 → 12 bayt).

## Handoff

- **Commit:** `6ada02d` (kod + testler) — dal `task/T-213-game-display-codecs` (`task/T-213-game-display-protocol` üstünde).
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Messages.swift`, `host-mac/Tests/MateBridgeCoreTests/FixtureTests.swift`, `host-mac/Tests/MateBridgeCoreTests/CodecTests.swift` (*listede yok*, aşağıya bak), `client-android/.../protocol/Messages.kt`, `Codec.kt`, `client-android/.../test/.../protocol/FixtureTest.kt`, `client-android/.../test/.../protocol/CodecRulesTest.kt` (*listede yok*), bu kart. PROTOCOL.md, gen.py, .hex dokunulmadı.
- **Varsayımlar:** Grup "kalan bayt > 0" ile algılanır; ≥12 baytta fazlası her mesajdaki gibi yok sayılır. `normalized` ekran alanlarını doğrulamadan geçirir (politika T-214). Çağıran kod değişmedi; herkes 0×0 gönderir/alır, tel baytları eski fixture'larla aynı. `StreamPrefsStore` (host, T-049) ekran alanlarını henüz saklamıyor (T-214 işi).
- **Test edilmeyenler / cihazda doğrulananlar:** Cihaz testi yok (davranış değişmiyor). `./scripts/check.sh` ALL OK, `gen.py --check` yeşil. XCTest/Swift Testing: `streamPrefsOptionalDisplayGroupIsAllOrNothing` + fixture testleri; JVM: `CodecRulesTest.streamPrefsOptionalDisplayGroupIsAllOrNothing` + `FixtureTest`.
- **Açık sorular:** `CodecTests.swift` ve `CodecRulesTest.kt` kartın `files:` listesinde yoktu ama dokunmak zorunluydu: ikisindeki eski kural testi STREAM_PREFS'e 2 fazla bayt ekleyip (10 bayt) kabul edilmesini bekliyordu; yeni kural (9–11 bayt kısa) bunu reddeder. Test `+ [0,0,0,0,9,9]` (14 bayt, grup 0×0, fazlası yok sayılır) olarak düzeltildi; yeni kenar testleri de bu iki dosyaya eklendi (yardımcı `frame`/`decodeOne` orada). Kotlin `FixtureTest` geçersiz fixture'larda hata türünü denetlemiyor; `SHORT_PAYLOAD` türü `CodecRulesTest`'te ayrıca denetlenir.
