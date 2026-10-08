---
id: T-310
title: Ölçüm — 2800×1840@60'ta çözme süresi kare süresini aşıyor (Günlük'te karelerin %31'i > 16,7 ms); saat, DVFS ve girdi yükseltmesi
status: done
phase: 7
owner: orchestrator
depends_on: [T-306]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-310-decode-clock-60fps.md
---

## Amaç

T-306 sonucu: kare atlamanın kaynağı zamanlayıcı ya da yakalama değil, çözme süresi.
- **Günlük 60:** çözme p50 15,4 ms, p90 20,3 ms; karelerin %31'i > 16,7 ms; 670 geç düşme / 9.935 kare; tutmalar %86 tek vsync, %12 iki vsync.
- **Oyun 60:** p50 14,0 ms; %6 > 16,7 ms; 231 geç düşme.
- Çizim 120'de çözme 9 ms (CB4).

Piksel hızı bunu açıklamıyor; yükseltilmiş saat durumu (Huawei girdi yükseltmesi) şüpheli.

## Yöntem

T-298 CB4 (`docs/reviews/2026-10-08/agents/opt-b-client.md`):
- aynı hareket sahnesinde parmak trackpad'de hareket ederken ve klavyeyle;
- `cpufreq/policy*/scaling_cur_freq` ve okunabiliyorsa `devfreq` 10 Hz;
- `KEY_FRAME_RATE` = 120 ya da tanımsız kolları (anahtar arkasında).

Debug olmayan derleme (T-301) ve release host ile tekrarlanır. Kullanıcı gerekirse trackpad'e dokunur.

## Plan

## Handoff

2026-10-08: neden dokunmasız düşük saat; dokunma yükseltmesi GPU'yu 442 MHz'e çıkarıyor ve çözme 16,5 → 11,4–12,4 ms. Devamı T-316 (sonuç: standart uygulama kaldıracı yok).

## Open questions
