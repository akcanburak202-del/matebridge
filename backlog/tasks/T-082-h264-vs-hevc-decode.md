---
id: T-082
title: Deney — H.264 ile HEVC karşılaştırması (tablette çözme süresi, kalite, uçtan uca gecikme)
status: todo
phase: 5
owner: orchestrator
depends_on: [T-077]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/
---

## Amaç

120 Hz bütçesi (NOTES 2026-10-01): host ~7 ms, USB+alım ~2–3, **tablet çözme ~9 ms (p95 12,6, p99 15)**, sunum ~11. HiSilicon çözücü H.264'ü HEVC'den hızlı çözebilir. Protokolde `StreamConfig.CODEC_H264` var; host ve tablet tarafında seçimin uçtan uca çalışıp çalışmadığı ve nasıl seçildiği önce kontrol edilmeli.

## Plan (orkestratör)

1. Kod tarafını oku: host H.264 kodlayabiliyor mu (VideoToolbox), codec seçimi nereden geliyor (env/STREAM_PREFS?), tablet `mime(config)` H.264 yolu. Eksikse uygulama kartı (mac-host-dev/android-client-dev, Opus).
2. Aynı bit hızında A/B: `pace_trace` ile çözme p50/p95/p99, SF aralıkları, kullanıcı çizimi (Akıcı mod 2800×1840@120); kalite için kullanıcının göz değerlendirmesi (yazı keskinliği).
3. Karar NOTES'a; kazanç varsa varsayılan/mod seçeneği.
