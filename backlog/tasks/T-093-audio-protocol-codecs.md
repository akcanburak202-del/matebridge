---
id: T-093
title: Ses protokolü kod çözücüleri (Swift + Kotlin): AUDIO_PREFS / AUDIO_CONFIG / AUDIO_FRAME, HELLO bit8 AUDIO_PCM
status: todo
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

(ajan doldurur, commit eder, sonra uygular)

## Handoff

