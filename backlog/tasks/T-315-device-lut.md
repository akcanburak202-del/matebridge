---
id: T-315
title: Host — sharp_nearest EOTF LUT'u `constant` adres uzayında cihazda daha yavaş; `device` adres uzayına geri dön
status: done
phase: 7
owner: mac-host-dev
depends_on: [T-314]
decisions: [0033]
files:
  - host-mac/Sources/MateBridgeCore/Video/SharpYUVKernel.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-315-device-lut.md
---

## Amaç

Cihaz ölçümü (aynı `scene.html?s=motion`, `sharp_nearest` Metal geçişi `gpu_ms` p50):

| Sürüm | `gpu_ms` p50 |
|---|---|
| Özgün iki geçişli kernel, LUT `device` | **2,50** |
| T-311 birleşik kernel | 2,99 |
| T-314 iki geçişli kernel, LUT `constant` | **4,18** |

Veriye bağlı LUT indekslemesi `constant` bellekte Apple GPU'larında serileşiyor. T-314'ün "constant LUT ayrı küçük kazanç" varsayımı yanlış çıktı. Bu kart LUT'u T-311 öncesi gibi `device` adres uzayına geri alır; T-314'ün geri kalanı (iki geçiş, HA1, A8) aynen kalır.

## Kabul

1. `SharpYUVKernel.metalSource` içinde `lut` parametreleri `device const float *` olur (`to_linear`, `luminance`, `rebuilt`, `reach`, `sharp_luma`); başka değişiklik yok.
2. Bit-exact testler (`LegacyTwoPassKernel` ve CPU referansı) geçer.
3. Cihaz (orkestratör): `gpu_ms` p50 ≈ 2,5 ms'ye dönmeli.

## Plan

`SharpYUVKernel.metalSource` içindeki `constant float *lut` -> `device const float *lut` (altı yer + doc yorumu). `ChromaConverter` değişmez (tamponu zaten `setBuffer` ile bağlıyor).

## Handoff

**Geri alındı (2026-10-08):** T-314 ile birlikte (bkz. T-314 Handoff). `constant` ve `device` LUT farkı aynı dakikada ölçülmedi; GPU saat durumu sonuçlara karışmıştı.

- Commit: `git log task/T-315-device-lut -1`.
- Dosyalar: `SharpYUVKernel.swift` (+ bu kart). Test dosyası değişmedi; `testProductionKernelsAreBitExactWithDeviceLUTSource` artık üretim kaynağıyla referans aynı adres uzayında.
- `check.sh`: ALL OK.
- Test edilmedi: cihaz `gpu_ms` (p50 ~2,5 ms beklenir). Host çalıştırılmadı, tablete dokunulmadı.

## Open questions

Yok.
