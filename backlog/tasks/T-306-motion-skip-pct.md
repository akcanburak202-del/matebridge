---
id: T-306
title: 60 fps içerik 60 Hz panelde %15–35 skip_pct — zamanlayıcı mı, panel mi, ölçüt mü
status: todo
phase: 7
owner: orchestrator
depends_on: [T-296]
decisions: [0014]
files:
  - docs/NOTES.md
  - backlog/tasks/T-306-motion-skip-pct.md
---

## Amaç

T-296 S2 (tam ekran hareket, 60 fps, Günlük 60):
- 60 sn kolda `skip_pct` %35, 8 dk kolda %15;
- `shown_p95` 33 ms (iki vsync), `cap_dec` p50 29 ms, `dec_p50` 15,9 ms.

Panel hızında içerikte bu kadar atlama beklenmiyor. T-208/T-210 Oyun modunda faz kilidiyle %0'a inmişti; Günlük modda durum ölçülmedi.

## Yöntem

- Aynı sahne, `--ez pace_trace true`, Günlük 60 ve Oyun 60, 3'er dk.
- `tools/pacing` ile tutma dağılımı (1/2/3 vsync), `phase_lock`, `path=`.
- `dec_p50` 15,9 ms periyoda (16,7 ms) çok yakın. Çözücü süresi mi taşıyor (CB4 ile ilgili)?
- Çıktı: NOTES girdisi ve gerekirse uygulama kartı.

## Plan

## Handoff

## Open questions
