---
id: T-082
title: Deney — H.264 ile HEVC karşılaştırması (tablette çözme süresi, kalite, uçtan uca gecikme)
status: done
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

## Sonuç (2026-10-01)

Bırakıldı. Kodlayıcı düğmesi T-086'da eklendi (`MATEBRIDGE_CODEC=h264`). Bench (M6, 2800×1840@120, `--encode-bench`):

| codec / profil | kodlama süresi | 120 fps'te sonuç |
|---|---|---|
| HEVC | p50 ~6,1 ms | sorun yok |
| H.264 High (`level_idc=60`) | ~24 ms | en fazla ~103 fps, Mac kodlayıcısı yetişmiyor |
| H.264 `High_5_2` | — | her kare hata veriyor (60 fps'te çalışıyor) |

H.264 Akıcı modda kullanılamaz. Netlik modunda (60 Hz) tablette çözme darboğaz değil, HEVC de bit başına daha keskin. Bu yüzden tablet A/B'sine gerek görülmedi.
