---
id: T-307
title: Protokol — str8 içinde geçersiz UTF-8 iki tarafta da protokol hatası (E9); fixture invalid_str8_utf8
status: done
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - host-mac/Sources/MateBridgeCore/Protocol/
  - host-mac/Sources/MateBridgeCore/ByteIO.swift  (orchestrator; the actual Swift change)
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

(orkestratör, sonradan kaydedildi) 1) PROTOCOL §1 kuralı ve `invalid_str8_utf8` fixture (`ddeea940`); 2) Swift `ByteIO.str8` doğrulamalı çözme (`74c40ede`); 3) Kotlin fixture testi negatif listeye (`a6c0bdb8`).

## Handoff

- Birleştirme `259728e1`; birleşmeden sonra tam `./scripts/check.sh` ALL OK (iki taraf fixture testleri dahil). Codex high: çalışma zamanı bulgusu yok.

Kotlin: `invalid_str8_utf8` added to the `invalid` set in FixtureTest.kt; no Codec change (INVALID_STRING already rejects). Device check: none needed (JVM tests only).

Swift part (acceptance 2) done by mac-host-dev. Commit: HEAD of task/T-307-str8-utf8 ("T-307: Swift str8 read rejects invalid UTF-8").
- Touched: `host-mac/Sources/MateBridgeCore/ByteIO.swift` (str8 read uses `String(validating:as:UTF8.self)`, invalid -> `ProtocolError.invalidField("str8 utf8")`), `host-mac/Tests/MateBridgeCoreTests/FixtureTests.swift` (`invalid_str8_utf8` expectation).
- Note: ByteIO.swift lives in `MateBridgeCore/`, not `MateBridgeCore/Protocol/` (card `files:` path is slightly off).
- `./scripts/check.sh --only host,protocol` passes. Full check.sh android part fails until the Kotlin step adds the fixture to its test.
- Nothing hardware-dependent.

## Open questions
