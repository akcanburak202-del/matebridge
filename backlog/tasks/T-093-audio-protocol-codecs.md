---
id: T-093
title: Ses protokolü kod çözücüleri (Swift + Kotlin): AUDIO_PREFS / AUDIO_CONFIG / AUDIO_FRAME, HELLO bit8 AUDIO_PCM
status: review
phase: 5
owner: mac-host-dev
depends_on: []
decisions: [0011]
files:
  - host-mac/Sources/MateBridgeCore/Protocol/
  - host-mac/Tests/
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/test/
  - backlog/tasks/T-093-audio-protocol-codecs.md
---

## Amaç

Karar 0011 ses mesajlarını ekledi. `docs/PROTOCOL.md` §4 (0x30–0x32, HELLO bit8, §5 ses kuyrukları, §8 fixture listesi) ve `protocol/fixtures/` bu dalda orkestratör tarafından güncellendi. İki tarafın kod çözücüleri ve fixture testleri burada eklenir; davranış (yakalama/çalma) T-094/T-095'te.

## Kabul kriterleri

- [x] Swift (`MateBridgeCore`) ve Kotlin (`protocol/`) için `AudioPrefs`, `AudioConfig`, `AudioFrame` tipleri encode/decode. Alan sırası ve tipleri PROTOCOL.md ile birebir aynı.
- [x] Doğrulama kuralları birebir PROTOCOL.md:
  - `AUDIO_FRAME` payload'u `28 + data_len`'den kısaysa, `frame_count` 0 ise ya da 960'tan büyükse protokol hatası. Fazla bayt yok sayılır.
  - `AUDIO_CONFIG`'te bilinmeyen `state`/`format` decode'da **hata değil** (değer korunur, uygulama yok sayar).
  - `AUDIO_PREFS.enabled` 0/1 dışı → `false`.
- [x] HELLO `capabilities` bit8 `AUDIO_PCM` sabiti iki tarafta. Kotlin istemci HELLO'da bu biti **henüz göndermez** (çalma T-095'te gelince açılır).
- [x] Mesaj gönderim yolları: Kotlin kontrol bağlantısında `AUDIO_PREFS` gönderebilecek, Swift kontrol bağlantısında `AUDIO_CONFIG`/`AUDIO_FRAME` gönderebilecek encode API'si (çağıran yok). Alım tarafında bilinen tip olarak decode edilip olay olarak üst katmana iletilir ya da şimdilik yok sayılır (davranış değişmez).
- [x] Fixture testleri: yeni beş fixture iki tarafta da kapsanır (`everyFixtureFileHasATestCase` ve Kotlin karşılığı geçer).
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Swift tipleri** yeni dosyada: `host-mac/Sources/MateBridgeCore/Protocol/AudioMessages.swift`.
   - `AudioPrefs(enabled: Bool)`: decode'da `enabled == 1` ise true, başka her değer false.
   - `AudioConfig(streamID, state, format, sampleRate, channels, framesPerPacket)`: `state` ve `format` ham `UInt8` (`OpenCode` struct'ları `AudioState`/`AudioFormat`), bilinmeyen değer korunur. `isPlayablePCM` yardımcısı.
   - `AudioFrame(streamID, seq, sampleIndex, captureTimeUs, frameCount, data)`: `data_len` = `data.count`. Decode sırası: alanlar, `frame_count` 1...960 değilse `invalidField("frame_count")`, sonra `data` (`r.raw(dataLen)` kısa ise `payloadTooShort(0x32)`). Fazla bayt yok sayılır.
2. **Swift bağlantı** (zorunlu, minimal): `ProtocolConstants.swift` (`MessageType` 0x30–0x32 + `audioMaxFrames = 960`), `Message.swift` (`.audioPrefs/.audioConfig/.audioFrame` case'leri, encode/decode; `checkedPayload` frame_count 1...960 ve data_len ≤ 65535 doğrular), `Messages.swift` (`Capabilities.audioPCM` bit8).
   - `Session/SessionMachine.swift` `handleCommon` switch'i exhaustive: `.audioPrefs` şimdilik yok sayılır (`[]`), `.audioConfig/.audioFrame` yanlış yön → yok sayılır. Davranış değişmez (önceden bilinmeyen tip olarak atlanıyordu).
   - Not: kartta listelenen `MateBridgeCore/Protocol/` dizini yoktu; protokol codec'i `MateBridgeCore/` kökünde. Bu dosyalara dokunmak kabul kriterleri için kaçınılmaz (bkz. Açık sorular).
3. **Kotlin** (`protocol/` içinde): `Messages.kt`'ye `MsgType.AUDIO_*`, `Capabilities.AUDIO_PCM`, `AudioPrefs`/`AudioConfig`/`AudioFrame` data class'ları; `Codec.kt`'ye encode/decode, aynı doğrulama (`INVALID_VALUE` frame_count, `SHORT_PAYLOAD` data). `MainActivity` HELLO capabilities'e dokunulmaz (bit8 gönderilmez). Session `when`'leri `else` dallı, değişiklik gerekmez; `ControlLink.send(AudioPrefs)` zaten çalışır.
4. **Testler:** iki tarafta fixture tablolarına 4 geçerli + 1 geçersiz fixture. Ek kural testleri: enabled 2 → false, bilinmeyen state/format korunur, frame_count 0 / 961 → hata, fazla bayt yok sayılır, encode frame_count doğrulaması, AUDIO_PCM = 0x100.
5. `./scripts/check.sh` ALL OK, commit, Handoff.

## Handoff


- **Commit:** `930c38e` (uygulama), `8bdc51f` (plan). Dal: `task/T-093-audio-codecs`.
- **check.sh:** ALL OK (swift build/test 522 test, gradle client + probe, fixtures up to date, crypto vectors).
- **Dokunulan dosyalar:**
  - Swift: `MateBridgeCore/Protocol/AudioMessages.swift` (yeni: `AudioPrefs`, `AudioConfig`, `AudioFrame`, `AudioState`/`AudioFormat` OpenCode), `MateBridgeCore/Message.swift` (3 case, encode/decode, `checkedPayload` frame_count 1...960 ve data ≤ 65535), `MateBridgeCore/ProtocolConstants.swift` (`MessageType` 0x30–0x32, `audioMaxFrames`), `MateBridgeCore/Messages.swift` (`Capabilities.audioPCM`), `MateBridgeCore/Session/SessionMachine.swift` ve `MateBridgeCore/Input/InputStateMachine.swift` (exhaustive switch'lere yeni case'ler; ikisi de yok sayar).
  - Swift test: `Tests/MateBridgeCoreTests/AudioCodecTests.swift` (yeni), `FixtureTests.swift` (5 fixture).
  - Kotlin: `protocol/Messages.kt` (`MsgType.AUDIO_*`, `Capabilities.AUDIO_PCM`, 3 data class), `protocol/Codec.kt` (encode/decode). Test: `protocol/AudioCodecTest.kt` (yeni, 14 test), `protocol/FixtureTest.kt` (5 fixture).
- **Davranış:** değişmez. Host `AUDIO_PREFS`'i decode edip yok sayar (önceden bilinmeyen tip olarak atlanıyordu). İstemcide `AUDIO_CONFIG`/`AUDIO_FRAME` `SessionMachine.onMessage`'ın `else` dalına düşer. `MainActivity` HELLO capabilities değişmedi, bit8 gönderilmez. Gönderim API'si: Swift `SessionAction.send(id, .audioConfig/.audioFrame)` ya da `Message.encode()`/sealed; Kotlin `ControlLink.send(AudioPrefs(..))`.
- **Hata türleri (iki tarafta aynı sıra):** önce sabit alanlar okunur (kısa → `payloadTooShort(0x32)` / `SHORT_PAYLOAD`), sonra `frame_count` 1–960 değilse `invalidField("frame_count")` / `INVALID_VALUE`, sonra `data_len` bayt (kısa → `payloadTooShort` / `SHORT_PAYLOAD`). `invalid_audio_frame_short` → `payloadTooShort(type: 0x32)`.
- **Varsayımlar:** `AUDIO_FRAME` sabit kısmı **28 bayt** (fixture'lara göre; bkz. Açık sorular). `data_len` ile `frame_count × channels × 2` uyuşmazlığı codec'te hata değil (istemcinin işi, T-095).
- **Test edilmeyen:** gerçek donanım gerekmiyor; yalnızca saf codec. Cihaz testi yok (adb/host çalıştırılmadı).

### Açık sorular

1. **PROTOCOL.md / kart hatası, 32 değil 28:** `AUDIO_FRAME` alanları 2+2+4+8+8+2+2 = **28 bayt**. `audio_frame.hex` `length = 44 = 28 + 16`. PROTOCOL.md 0x32 ve kart "payload `28 + data_len`'den kısaysa protokol hatası" diyor. 32 ile geçerli `audio_frame` fixture'ı (44 < 48) reddedilirdi. Kod 28 kullanır (`AudioFrame.fixedSize` / `AudioFrame.FIXED_BYTES`). Orkestratör PROTOCOL.md'deki "32"yi "28" yapmalı. `invalid_audio_frame_short` (length 32 < 28+16) her iki yorumda da reddedilir, fixture değişmez.
2. **Kapsam:** kartın `files:` listesindeki `host-mac/Sources/MateBridgeCore/Protocol/` dizini yoktu; Swift protokol codec'i `MateBridgeCore/` kökünde (`Message.swift`, `Messages.swift`, `ProtocolConstants.swift`). Kabul kriterleri bu dosyalara dokunmadan karşılanamıyordu. Yeni tipler listelenen `Protocol/` dizinine kondu; köke yalnızca minimal bağlama eklendi. `Message` enum'una case eklemek iki exhaustive switch'i de kırdı (`Session/SessionMachine.swift`, `Input/InputStateMachine.swift`): ikisine de yalnızca yok sayan case eklendi. Reviewer bu sapmayı onaylamalı.
