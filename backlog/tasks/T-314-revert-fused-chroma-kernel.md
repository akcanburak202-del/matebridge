---
id: T-314
title: Host — T-311 birleşik sharp_nearest kernel'i cihazda daha yavaş; iki geçişli kernel'e geri dön (HA1 iz aşaması ve A8 ortak kurulum kalır)
status: done
phase: 7
owner: mac-host-dev
depends_on: [T-311]
decisions: [0033]
files:
  - host-mac/Sources/MateBridgeCore/Video/SharpYUVKernel.swift
  - host-mac/Sources/MateBridgeHost/Video/ChromaConverter.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-314-revert-fused-chroma-kernel.md
---

## Amaç

T-311 sonrası cihaz ölçümü (2026-10-08 ~15:05, aynı `scene.html?s=motion`, Günlük 60, 2800×1840, `chroma_stats` 600 karelik pencereler):

| Sürüm | `conv_ms` p50 | `gpu_ms` p50 |
|---|---|---|
| T-311 öncesi (iki geçiş) | 3,27–3,48 | **2,50** |
| T-311 (birleşik) | 3,47–3,50 | **2,98–3,02** |

Bench'teki (%10–15 daha hızlı) kazanç gerçek akışta tutmadı. Muhtemel neden: blok başına tek iş parçacığı paralelliği 4× azaltıyor, 4 luma araması seri koşuyor. GPU süresi ~0,5 ms arttı.

## Kabul

1. `sharp_nearest` (ve plain) için iki geçişli kernel'e (T-311 öncesi `sharp_chroma` + `sharp_luma`) geri dönülür. Kaynak `Tests/.../LegacyTwoPassKernel.swift`'te duruyor; üretime geri taşınır, testteki kopya referans olarak kalabilir.
2. **Kalanlar:**
   - LUT'un `constant` adres uzayında olması, yalnız iki geçişli kernel'de bit-exact kalıyorsa tutulur (ayrı küçük kazanç); kalmıyorsa geri alınır;
   - HA1 (`gpu` aşaması, `latency.csv` sütunları);
   - A8 (`MetalShared`/`MetalPassSupport`).
3. **Bit-exact:** CPU referansına göre testler geçer. Birleşik kernel testleri ve bench kaldırılır ya da yalnız referans olarak bırakılır.
4. **Cihaz (orkestratör):** aynı sahnede `gpu_ms` p50 ≈ 2,5 ms'ye dönmeli.

## Plan

## Handoff

**Geri alındı (2026-10-08 ~15:45, orkestratör):** T-314 kararı karışık bir karşılaştırmaya dayanıyordu. Mac GPU süresi, kodun değil, o anki GPU saat ve güç durumunun etkisinde: T-311 öncesi sürüm de aynı saatte 4,22 ms ölçtü. Aynı dakikalarda dönüşümlü A/B: birleşik 3,67/3,49 ms, iki geçiş 3,92/3,51 ms (`gpu_ms` p50); `conv_ms` birleşikte ~0,2 ms daha kısa. T-314 ve T-315 birleştirmeleri `git revert` ile geri alındı; kernel T-311 haline döndü.

## Open questions
