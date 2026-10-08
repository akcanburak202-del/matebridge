---
id: T-316
title: Araştırma — dokunma olmadan Huawei DDR/GPU saatleri düşük kalıyor; uygulamanın kontrol edebileceği bir kaldıraç (çözme 15,4 → 11,4 ms, cap_dec −15 ms)
status: done
phase: 7
owner: orchestrator
depends_on: [T-310]
decisions: []
files:
  - docs/research/2026-10-08-ddr-clock.md
  - backlog/tasks/T-316-ddr-clock-lever.md
---

## Amaç

T-310 ölçümü (2026-10-08 ~15:30; Günlük 60, hareket sahnesi, 45 sn, saatler 10 Hz):

| | DDR (MHz, en sık) | GPU (MHz) | büyük çekirdek | çözme p50 | `cap_dec` p50 | `skip_pct` |
|---|---|---|---|---|---|---|
| dokunmasız | 1104 %40 / 749 %35 | 239 | 1210 | 15,4 ms | 33,8 ms | %11,9 |
| sentetik dokunuşla | **1536 %62** | 442 | 1210 / 2400 | **11,4 ms** | **19,1 ms** | %2,9 |

DDR'ın üst sınırı 3197 MHz. Çizim modu dokunmasızken de 16 ms; sabahki 9 ms'lik ölçüm kalemle dokunurken alınmıştı.

## Yöntem

Debug olmayan derlemede ve root olmadan denenecek adaylar; her biri A/B ve enerji bedeliyle (CB6):
- `PowerManager.isSustainedPerformanceModeSupported` / `Window.setSustainedPerformanceMode(true)`;
- ADPF `PerformanceHintManager` (API 31; HarmonyOS desteği belirsiz);
- `android:appCategory="game"` ya da Huawei oyun asistanı tanıması;
- MediaCodec `KEY_FRAME_RATE` = 120 ya da tanımsız, `KEY_PRIORITY`, vendor anahtarları (`vendor.hisi-*`);
- yüksek yenileme isteği (`preferredDisplayModeId` 120) dokunmasız DDR'ı etkiliyor mu;
- Huawei PerfGenius/HMS (bağımlılık; karar gerekir).

Ölçüm: aynı sahnede DDR/GPU frekansı, çözme p50, `cap_dec`, `skip_pct` ve pil/ısı.

## Kabul

1. `docs/research/2026-10-08-ddr-clock.md`: her aday için sonuç (çalıştı / çalışmadı / desteklenmiyor) ve enerji bedeli.
2. Çalışan bir kaldıraç varsa uygulama kartı ve gerekiyorsa karar kaydı.

## Plan

## Handoff

2026-10-08: `docs/research/2026-10-08-ddr-clock.md`. Uygulama tarafı standart kaldıraç yok; kalan yol Huawei'ye özgü bir API (yeni bağımlılık, karar ve kullanıcı onayı). T-318 birleştirilmedi.

## Open questions
