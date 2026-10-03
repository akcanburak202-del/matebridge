---
id: T-188
title: Check stream colour, range and chroma fidelity with test patterns
status: todo
phase: 6
owner: user
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/T-188-colour-range-check.md
---

## Amaç

The stream is SDR, 8-bit, 4:2:0 HEVC Main, tagged sRGB/BT.709 full range on both ends. Nobody has checked on the device whether black stays black, white stays white, the grey ramp is right, and how thin coloured text survives chroma subsampling. T-113 already found and fixed one real colour error (+8 luma levels), which shows this kind of check pays off. This card gives an explicit range verdict and documents the SDR/4:2:0 limit, so later quality work (4:4:4, chroma bench) starts from facts. The user runs it; the orchestrator prepares the test page and reads the logs.

Source: external architecture review 2026-10-03 (PF6, X11, D8); verification: docs/reviews/2026-10-03/verify-C-host-video.md (PF6-M).

## Bağlam

**Evidence at HEAD (a30c769):**
- Capture is `420YpCbCr8BiPlanarFullRange`, `colorSpaceName = sRGB`, `colorMatrix = 709` (`host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift:54-56`).
- The encoder session sets primaries 709, transfer sRGB and matrix 709 (`HEVCEncoder.swift:190-194`), and input buffers are retagged to the same values (T-113).
- `STREAM_CONFIG` sends H.273 primaries=1, transfer=13, matrix=1, full_range=1 (`host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift:95-107`). T-113 verified that the bitstream VUI matches.
- The client sets `KEY_COLOR_RANGE`/`STANDARD`/`TRANSFER` from `STREAM_CONFIG` (`client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:286-288`). It logs what the decoder reports in `MB/decoder ev=output_format range= standard= transfer=` (`VideoRenderer.kt:587-588`). The manifest calls this line `codec_format`; the real event name is `output_format`.
- The HEVC profile is Main: 8-bit 4:2:0 only. `--sharpness-bench` measures luma only, and its reference chroma is pre-averaged (`SharpnessBench.swift:17`, `:41-46`), so chroma loss is unmeasured. T-113's handoff left "colour/brightness comparison with the Mac" untested.
- **Caveat:** whole-screen PSNR between tablet and Mac screenshots is stuck at ~33.7 dB because of colour management (NOTES.md:562). Compare individual patch values and look by eye; do not compute PSNR.

**Procedure (user; the orchestrator prepares the page and collects the logs):**
1. Builds: record the host and APK commit SHAs (`ev=app_start` from T-145/T-146, or `git rev-parse --short HEAD` of each build), macOS and HarmonyOS builds, and the stream mode (Netlik 60, full resolution).
2. The orchestrator prepares a static HTML test page (scratch, not committed) with:
   - 1 px and 2 px red, green and blue text on white and on black;
   - a 0–255 grey ramp (256 steps);
   - flat patches at 0, 16, 235 and 255;
   - saturated colour bars (R, G, B, C, M, Y).
   Open it full-screen on the Mac virtual display.
3. Wait for the screen to be static (keyframe settled). Capture:
   - the tablet with `adb exec-out screencap -p > tab.png`;
   - the Mac virtual display with `screencapture -D <n>` (pick the MateBridge display).
4. Repeat at the default bitrate and at the maximum panel bitrate (100 Mbps).
5. Read the patch values from both PNGs (centre of each patch, a 5×5 average). The reference values are the page's authored values (0, 16, 235, 255). The Mac `screencapture` PNG is colour-managed too (see the ~33.7 dB note, NOTES.md:562), so it is only a sanity check. Judge the range verdict on the tablet screencap against the authored values:
   - range verdict: 0→0 and 255→255 within ±2; 16 and 235 are not crushed to 0/255;
   - ramp: monotonic with no banding jumps > 2 levels; T-113 predicted "slightly darker = correct";
   - thin coloured text: describe the fringing and readability by eye at 100 % zoom on the tablet (photo optional; no personal content on screen).
6. Copy the tablet `MB/decoder ev=output_format` line for the session.
7. Write a dated NOTES entry: build IDs, mode, both bitrates, the patch table, the ramp verdict, the text observation, and the `output_format` line. Add one paragraph documenting the SDR / 8-bit / 4:2:0 limit for README/PLAN (the orchestrator moves it in T-193).

**Follow-ups:**
- A follow-up fix card only if a defect is found (e.g. range crush or a level shift).
- T-201 (RGB-referenced chroma bench) only if the by-eye verdict on coloured text is inconclusive.
- 4:4:4 stays a PLAN Aşama 5 item, which is blocked by decoder support.

Wire: none.

## Kapsam dışı

- Code changes; a chroma bench (T-201); HDR or 10-bit; 4:4:4 experiments.

## Kabul kriterleri

- [ ] [device] Patch values for 0/16/235/255 from both screenshots at the default and the maximum bitrate, plus the explicit range verdict judged on the tablet screencap against the authored values (correct: 0→0, 255→255 ±2, no crush of 16/235; or the defect described).
- [ ] [device] Grey ramp verdict and the thin coloured text observation at both bitrates.
- [ ] [doc] docs/NOTES.md has a dated entry with the build IDs (host SHA, APK SHA, macOS and HarmonyOS builds), mode, bitrates, the `ev=output_format` line, the verdicts and the SDR/8-bit/4:2:0 limit paragraph.
- [ ] [doc] NOTES says whether a follow-up card or T-201 is needed, and why.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
