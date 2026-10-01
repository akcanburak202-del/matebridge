---
id: T-085
title: Deney — bit hızı/kodlayıcı kalite ayarı ile yazı keskinliği (Akıcı mod)
status: todo
phase: 5
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/
---

## Amaç

Varsayılan HEVC 30 Mbps (`VideoSettings`), `PrioritizeEncodingSpeedOverQuality=true`, 4:2:0. Akıcı modda (2800×1840@120) yazı keskinliği ve hareket sırasında bulanıklık göze dayalı değerlendirilmeli. `MATEBRIDGE_BITRATE_KBPS` düğmesi var (T-045).

## Plan (orkestratör)

1. 30 / 45 / 60 Mbps ve `PrioritizeEncodingSpeedOverQuality` açık/kapalı; kodlama süresi (`ev=latency enc`), USB'de varış düzensizliği (`gaps.py`), kullanıcının metin/çizim değerlendirmesi.
2. Kazanç varsa varsayılanı değiştirme kartı.
