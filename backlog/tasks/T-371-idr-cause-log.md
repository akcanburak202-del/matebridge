---
id: T-371
title: Host — her zorunlu IDR için neden günlüğü (ev=idr_forced cause=...)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-369]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeCore/Video/KeyframeRequestCoalescer.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoSender.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - tools/measure/mblog.py
  - tools/measure/game_ab.py
  - tools/measure/selftest.sh
  - tools/measure/testdata/
  - backlog/tasks/T-371-idr-cause-log.md
---

## Amaç

`docs/research/2026-10-23-forced-idr-chain.md` §5 madde 2. Bugün host kaynaklı IDR yalnız `net ev=stats idr=` sayısı olarak görünüyor; T-370 A/B'sinde hangi IDR'nin neden çıktığı ayırt edilemiyor.

## Kabul

1. Host her IDR zorlamasında (gerçekten kodlayıcıya `ForceKeyFrame` giden karar; birleştirilen/bastırılan istekler ayrı sayılır) tek satır: `video ev=idr_forced view=main|aux cause=queue_overflow|transport_refused|client_request|periodic|consumer|other` ve mümkünse `since_last_ms=`. Saniyede çok IDR'de log seli olmasın: saniyelik özet satırı (`ev=idr_causes queue_overflow=N ...`) veya hız sınırı; seçim Plan'da gerekçelenir.
2. Davranış değişmez (yalnız gözlem). Birim test: her yol doğru `cause` üretir.
3. `mblog.py` izin listesi yeni satırı tanır (sıkı desen); `game_ab.py` olay penceresi ve kol özetinde IDR'leri nedene göre sayar; selftest sentetik veriyle.
4. LOGGING.md güncel.
5. `./scripts/check.sh` geçer. Çalışan uygulamaya dokunma, Mac'te pencere açma, cihaz testi yok.

## Plan

(ajan yazar)

## Handoff

## Open questions
