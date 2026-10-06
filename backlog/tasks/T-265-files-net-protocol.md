---
id: T-265
title: Protocol — Wi-Fi tablet files (decision 0035): HELLO bit12, FILES_INFO STANDBY, FILES_NET, file connection 0x50–0x52, §9 file keys
status: review
phase: 6
owner: orchestrator
depends_on: []
decisions: [0035]
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - backlog/tasks/T-265-files-net-protocol.md
---

## Amaç

Karar 0035'in (ve 2026-10-06 ekinin) tel biçimi. Orkestratör yazar; Codex `--high`. Codec'ler T-267 (Swift) ve T-269 (Kotlin) kartlarında; fixture testleri her fixture dosyası için test istediğinden bu dal codec dallarıyla birlikte birleşir (T-257 gibi).

## Özet

- `HELLO.capabilities` bit12 `FILES_NET`.
- `FILES_INFO.state = 2` STANDBY (Wi-Fi, izinli, sunucu kapalı); eski host OFF sayar.
- 0x0A `FILES_NET` (H→C): `state u8` (0 CLOSE, 1 OPEN), `port u16`, `pool u8`, `max u8`.
- Dosya bağlantısı (tablet açar): 0x50 `FILES_HELLO` (düz: `protocol_version u16`, `session_id u32`, `client_files_nonce[16]`), 0x51 `FILES_HELLO_ACK` (düz: `status u8`, `host_files_nonce[16]`), sonra §9 kayıtları: ilk C→H PING (kanıt), 0x52 `FILES_DATA` (`size u16` 1…65 534, `data`). Havuz, 1:1 eşleme, mesajsız kapanma, canlı tutma (10 sn PING, 30 sn boşta kapanma).
- §9: `kf_c2h/kf_h2c` = Expand(prk, "MB1 files c2h|h2c" ‖ client_files_nonce ‖ host_files_nonce, 32).
- §5: dosya kuyrukları (64 KiB/bağlantı/yön, geri basınç), hız tavanı formülü.
- Fixture'lar: `files_info_standby`, `files_net_open`, `files_net_close`, `files_hello`, `files_hello_ack`, `files_hello_ack_rejected`, `files_data`, `invalid_files_hello_short`, `invalid_files_data_empty`; `crypto_vectors.json` dosya anahtarları + 3 kayıt (bağımsız Python HKDF ile doğrulandı).

## Handoff

## Open questions
