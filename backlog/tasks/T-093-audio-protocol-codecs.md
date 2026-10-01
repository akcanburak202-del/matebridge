---
id: T-093
title: Ses protokolü kod çözücüleri (Swift + Kotlin): AUDIO_PREFS / AUDIO_CONFIG / AUDIO_FRAME, HELLO bit8 AUDIO_PCM
status: in-progress
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

- [ ] Swift (`MateBridgeCore`) ve Kotlin (`protocol/`) için `AudioPrefs`, `AudioConfig`, `AudioFrame` tipleri encode/decode. Alan sırası ve tipleri PROTOCOL.md ile birebir aynı.
- [ ] Doğrulama kuralları birebir PROTOCOL.md:
  - `AUDIO_FRAME` payload'u `32 + data_len`'den kısaysa, `frame_count` 0 ise ya da 960'tan büyükse protokol hatası. Fazla bayt yok sayılır.
  - `AUDIO_CONFIG`'te bilinmeyen `state`/`format` decode'da **hata değil** (değer korunur, uygulama yok sayar).
  - `AUDIO_PREFS.enabled` 0/1 dışı → `false`.
- [ ] HELLO `capabilities` bit8 `AUDIO_PCM` sabiti iki tarafta. Kotlin istemci HELLO'da bu biti **henüz göndermez** (çalma T-095'te gelince açılır).
- [ ] Mesaj gönderim yolları: Kotlin kontrol bağlantısında `AUDIO_PREFS` gönderebilecek, Swift kontrol bağlantısında `AUDIO_CONFIG`/`AUDIO_FRAME` gönderebilecek encode API'si (çağıran yok). Alım tarafında bilinen tip olarak decode edilip olay olarak üst katmana iletilir ya da şimdilik yok sayılır (davranış değişmez).
- [ ] Fixture testleri: yeni beş fixture iki tarafta da kapsanır (`everyFixtureFileHasATestCase` ve Kotlin karşılığı geçer).
- [ ] `./scripts/check.sh` geçiyor.

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

