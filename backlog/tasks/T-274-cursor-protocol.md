---
id: T-274
title: Protocol — local cursor (decision 0036): HELLO bit13, CURSOR_PREFS 0x0B, CURSOR_SHAPE 0x0C, CURSOR_STATE 0x0D
status: review
phase: 6
owner: orchestrator
depends_on: [T-271]
decisions: [0036]
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - backlog/tasks/T-274-cursor-protocol.md
---

## Amaç

Karar 0036'nın tel biçimi. Orkestratör yazar; Codex `--high`. Codec'ler host (T-275) ve istemci (T-276) kartlarında; fixture testleri her fixture için test istediğinden bu dal codec dallarıyla birlikte birleşir.

## Özet

- HELLO bit13 `LOCAL_CURSOR`.
- 0x0B `CURSOR_PREFS` (C→H): `enabled u8`, `reserved u8`, `reserved2 u16`.
- 0x0C `CURSOR_SHAPE` (H→C): `shape_id u32`, `width_pt16/height_pt16/hot_x_pt16/hot_y_pt16 u16`, `format u8` (1 PNG), `reserved u8`, `data_len u16` (1…61 440), `data`.
- 0x0D `CURSOR_STATE` (H→C): `seq u32`, `x/y u16` (normalize, §1), `visible u8`, `reserved u8`, `shape_id u32`, `host_time_us u64`.
- Kurallar: açma/kapama sırası (imleç önce katmanda, sonra videodan kalkar), en az 500 ms'de bir durum, istemci 1,5 s zaman aşımında `CURSOR_PREFS(0)`, önbellek host 32 / istemci ≥ 64 (LRU), §5 tek bekleyen durum.
- Fixture'lar: `cursor_prefs_on`, `cursor_prefs_off`, `cursor_shape`, `invalid_cursor_shape_short`, `cursor_state`, `cursor_state_hidden`.

## Handoff

## Open questions
