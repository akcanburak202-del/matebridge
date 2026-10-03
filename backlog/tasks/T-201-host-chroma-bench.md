---
id: T-201
title: Add an RGB-referenced chroma metric and test patterns to SharpnessBench
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-188, T-186]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/SharpnessBench.swift
  - host-mac/Sources/MateBridgeCore/Video/ImageQuality.swift
  - host-mac/Sources/MateBridgeCore/Video/ChromaQuality.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/ChromaQualityTests.swift
  - backlog/tasks/T-201-host-chroma-bench.md
---

## Amaç

**Gated: start only after T-188 records in docs/NOTES.md that its by-eye colour check was inconclusive: either the range verdict (0→0 and 255→255 within ±2) could not be confirmed from the tablet `screencap` / Mac screenshot, or colour fringing on 1–2 px red/blue/green text was seen but could not be attributed to 4:2:0 subsampling vs a range/transfer error. If T-188 gives a clear verdict (pass, or a defect with its own fix card), this card is closed as won't-do.**

`--sharpness-bench` measures luma only, and its reference chroma is already 2×2-averaged at the source, so it cannot see what 4:2:0 and range/transfer tagging do to thin coloured text. This card adds an RGB-referenced chroma metric and the T-188 test patterns to the bench, giving a numeric answer where the eye and colour-managed screenshots cannot.

Source: external architecture review 2026-10-03 (X11, PF6); verification: docs/reviews/2026-10-03/verify-H-hygiene.md.

## Bağlam

**Evidence (HEAD a30c769):**
- The bench compares decoded output with the source **luma** (PSNR, 8×8 SSIM) (`SharpnessBench.swift:9-20`). The page is converted RGBA → full-range BT.709 Y plus **2×2-averaged** CbCr (`Page`, `:39-50`; `toYCbCr`, `:121-122`), so the reference is already subsampled.
- Pure metrics live in `host-mac/Sources/MateBridgeCore/Video/ImageQuality.swift` (`LumaPlane`, `psnr`, `ssim`); options in `SharpnessBenchOptions.swift`. There is no dedicated `ImageQuality` test file today; `IdleRefreshRefineTests` and `EncoderKnobsTests` touch the bench options.
- On-device screenshot PSNR is unusable (stuck at ~33.7 dB from colour management, `docs/NOTES.md:562`). T-113 found a real +8 luma-level gamma error (`docs/NOTES.md:758-806`, +8 levels at :799), the class of error this metric targets.
- 4:4:4 is a PLAN Aşama 5 experiment and the tablet decoder may not support it (`docs/PLAN.md:86`); this card only measures.

**Plan hints (H IQ-1):**
- Keep the RGB source of each pattern; after decode, convert the decoder output back to RGB with the stream's tagged matrix/range and compare against the RGB reference: per-pattern ΔE (e.g. CIEDE2000 or ΔE76, pick one and justify) or CbCr PSNR against **full-resolution** source chroma, plus luma PSNR.
- Patterns (same as T-188): 1–2 px red, blue and green text on white and on black; a 0–255 grey ramp; 0/16/235/255 patches; colour bars; one moving pattern.
- Bitrates: 30/60/80 Mbps through the bench's existing env knobs.
- New pure helpers go in `ChromaQuality.swift` (or extend `ImageQuality.swift`; choose in Plan).

**Serialize with** T-186 (`SharpnessBench.swift`: T-186 removes retired knob plumbing such as idle refresh from the bench). Read the file after T-186 lands.

Wire: none.

## Kapsam dışı

- Changing encoder colour settings, range tagging or the codec (a defect gets its own card).
- A 4:4:4 experiment.
- Tablet-side screenshots or any client change.

## Kabul kriterleri

- [ ] [XCTest] The chroma metric on synthetic inputs: identical images → ΔE 0 / infinite PSNR; a known 4:2:0 round trip of 1 px red text gives a non-zero, stable value; a deliberate range error (full↔limited) is detected above a stated threshold.
- [ ] The bench prints, per pattern and per bitrate (30/60/80 Mbps), the chroma metric and luma PSNR in one numeric table (no image dumps committed).
- [ ] [device] (Mac only) One bench run recorded in NOTES with the host SHA, mode and codec, and a one-line verdict: is the fringing explained by 4:2:0, and is the range correct.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
