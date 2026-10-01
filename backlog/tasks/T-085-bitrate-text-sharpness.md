---
id: T-085
title: Deney — bit hızı/kodlayıcı kalite ayarı ile yazı keskinliği (Akıcı mod)
status: done
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

## Sonuç (2026-10-01)

Varsayılanlar değişmiyor: HEVC, Akıcı 60 Mbps, `PrioritizeEncodingSpeedOverQuality=true`, boşta tazeleme kapalı. Ayrıntılar NOTES 2026-10-01 ~15:30 ve ~17:30.

- Durağan metin, oturmuş akışta (bench, 240 kare) 48,5 dB. 80 Mbps ya da `QUALITY=0.8` ile 53 dB, ama hareket kareleri de büyüyor; cihazda bunun maliyeti +2–3 ms gecikme. Kullanıcı gecikmeyi öncelikli tutuyor.
- Boşta tazeleme `fast` profilde etkisiz (T-087): son kare zaten bu bit hızındaki en düşük QP'de. Akış ortasında hiçbir VT ayarı `fast` profilde etki etmiyor.
- Deney düğmeleri (T-086/T-087) duruyor. Kullanıcı yazıyı yetersiz bulursa ilk denenecek: `MATEBRIDGE_BITRATE_KBPS=80000`.
