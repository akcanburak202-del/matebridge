---
id: T-257
title: Protocol — packed full chroma (decision 0034): STREAM_PREFS.chroma=2, STREAM_CONFIG.chroma_layout, VIDEO_FRAME.view, KEYFRAME_REQUEST.view
status: done
phase: 6
owner: orchestrator
depends_on: [T-254, T-255, T-256]
decisions: [0034]
files:
  - docs/PROTOCOL.md
  - protocol/fixtures/
  - docs/decisions/0034-full-chroma-packed-444.md
  - backlog/tasks/T-257-full-chroma-protocol.md
---

## Amaç

Karar 0034'ün tel biçimi. Orkestratör yazar; Codex `--high`. Codec'ler T-258 (Swift) ve T-259 (Kotlin) kartlarında.

## Handoff

- Dal `task/T-257-full-chroma-protocol`. PROTOCOL §0x03 `chroma_layout`, §0x05 `chroma = 2` + host kuralı, §0x23 isteğe bağlı `view`, §0x41 `view` + akış başına `frame_seq` + yardımcı `capture_time_us` eşlemesi + gönderim sırası, §5 yardımcı kuyruğu (ve T-252 yetişme kuralı belgelendi), §8 fixture listesi.
- Yeni fixture'lar: `stream_prefs_full_chroma`, `stream_config_packed444`, `video_frame_aux`, `video_frame_aux_config`, `keyframe_request_view`. Var olanlar bayt bayt aynı, yalnız alan adları (`reserved` → `chroma_layout` / `view`).
- Bu dalda Swift/Kotlin fixture testleri alan adları yüzünden kırılır; T-258/T-259 düzeltir.
- Codex `--high` 1. tur: P1 (fixture'lar test kayıtlarında yok → dal tek başına check.sh geçmez) beklenen; T-257/T-258/T-259 birlikte birleştirilir (0032/0033 deseni). P2 oturum başına onay → `HELLO.capabilities` bit11 `FULL_CHROMA` + "bu oturumda `chroma = 2`" kuralı eklendi. P2 "ana asla atlanmaz" → ana akış §5 sınırlı kuyruk kurallarına tabi, önce yardımcı atılır.
