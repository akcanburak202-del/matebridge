---
id: T-307
title: Protokol — str8 içinde geçersiz UTF-8 iki tarafta da protokol hatası (E9); fixture invalid_str8_utf8
status: todo
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - host-mac/Sources/MateBridgeCore/Protocol/
  - host-mac/Tests/MateBridgeCoreTests/
  - client-android/app/src/test/kotlin/dev/matebridge/client/protocol/
  - backlog/tasks/T-307-str8-invalid-utf8.md
---

## Amaç

T-297 E9 (`docs/reviews/2026-10-08/agents/simp-e-protocol.md`), kullanıcı kararı 2026-10-08: iki taraf da reddeder. Bugün:
- Swift `ByteIO` `String(decoding:)` ile kayıplı kabul ediyor (~:84);
- Kotlin `Codec.kt` ~71-79 `INVALID_STRING` ile reddediyor;
- PROTOCOL §1 bir şey söylemiyor.

## Kabul

1. **Orkestratör:**
   - PROTOCOL §1 `str8` tanımına "geçerli UTF-8 değilse protokol hatası" eklenir;
   - `protocol/fixtures/invalid_str8_utf8` (geçersiz UTF-8 taşıyan bir `str8` alanlı mesaj, ör. HELLO `device_name`) ve beklenen hata eklenir; fixture üreteci `--check` geçer.
2. **Swift (mac-host-dev):** `ByteIO` str8 okuması geçersiz UTF-8'de protokol hatası verir; fixture testi geçer.
3. **Kotlin (android-client-dev):** fixture testi yeni negatif örneği tanır (davranış zaten doğru).
4. Fixture testleri iki tarafta da geçer.

## Plan

## Handoff

## Open questions
