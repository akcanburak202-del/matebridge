---
id: T-007
title: Protokol v0 taslağı ve altın örnekler
status: todo
phase: 0
owner: orchestrator
depends_on: [T-003, T-004, T-005]
decisions: [0001, 0003]
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - docs/NOTES.md
  - scripts/check.sh
  - docs/decisions/0003-keyboard-physical-keycodes.md
---

## Amaç

Aşama 0 bulgularına dayanarak Mac ve tabletin konuşacağı mesajları dondurmak. Bu kart bitmeden host ve client paralel kodlamaya başlamaz.

## Kabul kriterleri

- [ ] Aşama 0 bulguları `docs/NOTES.md`'de özetlendi (kalem alanları ve örnekleme hızı, klavye scan code'ları, trackpad davranışı, sanal ekran sonuçları).
- [ ] `docs/PROTOCOL.md`: çerçeveleme, HELLO/yetenekler, video kare başlığı, kalem örneği (toplu + geçmiş örnekler), tuş, işaretçi, kaydırma, dokunma, release-all, heartbeat, istatistik.
- [ ] Her mesaj için `protocol/fixtures/*.hex`.
- [ ] Codex incelemesi (`--high`) yapıldı, bulgular işlendi.
- [ ] Kullanıcıya Aşama 0 raporu sunuldu, Aşama 1'e geçiş onayı alındı.

## Handoff

- **Açık sorular:**
