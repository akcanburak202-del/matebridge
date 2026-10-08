---
id: T-314
title: Host — T-311 birleşik sharp_nearest kernel'i cihazda daha yavaş; iki geçişli kernel'e geri dön (HA1 iz aşaması ve A8 ortak kurulum kalır)
status: review
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

1. `SharpYUVKernel.metalSource` := T-311-öncesi `sharp_chroma` + `sharp_luma` (LegacyTwoPassKernel kaynağından), LUT `constant float *`.
2. `ChromaConverter`: iki pipeline, tek command buffer'da iki encoder; `MetalPassSupport.run(encodeBuffer:)` aşırı yüklemesi eklendi (tek-encoder `run` PackedChromaPacker için aynı kaldı).
3. Testler: üretim iki geçiş (constant LUT) == LegacyTwoPassKernel (device LUT) bayt-bayt; CPU referansına <=1; birleşik bench kaldırıldı.

## Handoff

- Commit: `git log task/T-314-revert-fused -1` (T-314 commit).
- Dosyalar: `SharpYUVKernel.swift`, `ChromaConverter.swift`, `SharpYUVTests.swift` (+ bu kart).
- `check.sh`: ALL OK (1034 test). Yeni kapı `testProductionKernelsAreBitExactWithDeviceLUTSource` gerçek Metal'de koştu (skip değil): 8 boyut x noise/mixed x plain/nearest, Y ve CbCr bayt-bayt eşit; CPU referansına <=1 ve aynı fark sayısı.
- LUT `constant` adres uzayı iki geçişli kernelde bit-exact kaldı, tutuldu.
- HA1 (gpu aşaması, latency.csv) ve A8 (MetalShared/MetalPassSupport) korundu; `MetalPassSupport` yalnız `run(encodeBuffer:)` kazandı.
- `LegacyTwoPassKernel.swift` test referansı olarak duruyor. Birleşik kernel ve bench silindi.
- Test edilmedi: cihaz (`gpu_ms` p50 ~2,5 ms'ye dönmeli; `constant` LUT'un tek başına etkisi cihazda görülür). Host çalıştırılmadı.

## Open questions
