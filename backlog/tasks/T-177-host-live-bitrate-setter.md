---
id: T-177
title: Add a live encoder bitrate setter (no restart) and verify VT honours it
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-162, T-176]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/LOGGING.md
  - backlog/tasks/T-177-host-live-bitrate-setter.md
---

## Amaç

Today any bitrate change restarts capture and the encoder, and the client has to reconnect video and receive a fresh IDR. A restart costs exactly the keyframe burst that hurts Wi-Fi, so the restart path cannot be used as an in-session lever. This card adds a setter that changes the bitrate of the live VideoToolbox session, and checks on the real M6 encoder how fast frame sizes follow. It is the building block for a fixed Wi-Fi profile (T-178) and any later adaptation (T-196).

Source: external architecture review 2026-10-03 (H03, A6); verification: docs/reviews/2026-10-03/verify-F-network.md (F-1, additional issue A-3).

## Bağlam

**Evidence at HEAD (a30c769):**
- `AverageBitRate` and `DataRateLimits` are set only at creation (`host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:168-184`).
- `DataRateLimits` is `[2 × average bytes, 1 s]` (`:182-184`). There is no short-window cap, so single frames of 100–450 KB are allowed (F A-3, LM7).
- With `MATEBRIDGE_QUALITY` accepted (`qualityApplied`), `AverageBitRate` is **not** set at all (`:167-181`). In that mode the setter can change only `DataRateLimits`, and the Handoff must say so.
- A live-property precedent exists: `MaxAllowedFrameQP` is changed on the running session before a submit (`updateQPBoost`, `:430-453`, T-087).
- Restart path today: `STREAM_PREFS` with a new bitrate → `StreamCoordinator.swift:373-389` (`applyPrefs`: new `config_id`, `STREAM_CONFIG`, video close) → `restartPipeline` (`:555-570`). PROTOCOL §0x05 requires this behaviour for **user** changes. This card does not change that path.
- Outside this repo, WebRTC's VideoToolbox encoder updates `AverageBitRate`/`DataRateLimits` mid-session, so a live update is plausible. Whether the M6 HEVC hardware encoder with `RealTime=false` (`.fast` profile, `:130-137`, `:159`) reacts quickly is unknown. Measure it; do not assume.

**Design hints:**
- Shape: `HEVCEncoder.setTargetBitrate(kbps:)` plus a pure Core value type for the rate request: clamp to `[floor, ceiling]` and deduplicate equal values. The pure type lives in `EncoderSubmitOrder.swift`, next to T-162's owner logic.
- **Ordering:** the setter must be serialised with submit, invalidate and stop through T-162's owner queue (`host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift`, created by T-162). Never call `VTSessionSetProperty` after `stop`.
- **Debug step knob** (`EncoderKnobs.swift`): steps the bitrate on a timer for the device check, e.g. `MATEBRIDGE_BITRATE_STEP=60000,15000,60000@5s`. It is default off. Per draft decision 0026, its doc comment names its closing card (T-196, or retire after T-127). Write the knob under *Açık sorular* so the orchestrator adds it to `docs/KNOBS.md` (not in `files:`).
- **Short-window `DataRateLimits` (F A-3):** also try a second pair, e.g. `[bytes, 0.1]` next to the 1 s pair. Report whether `VTSessionSetProperty` accepts it (status code) and whether single-frame sizes change. Diagnostics only; the default stays as today unless the orchestrator decides otherwise.
- Log `video ev=bitrate_set kbps=<n> avg_status=<OSStatus>|skipped limits_status=<OSStatus>`, numbers only, one line per actual change (deduplicated). Add the line to `docs/LOGGING.md`.
- `STREAM_CONFIG.bitrate_kbps` keeps meaning "the configured value". This card sends no new `STREAM_CONFIG`. Any "ceiling" semantics belong to decision 0023 / T-196 (orchestrator prose in §0x03 then).

**Ordering and serialization:**
- Hot-file chain on `HEVCEncoder.swift`: T-162 → T-170 → T-176 → T-177 → T-186 → T-187. The `depends_on` already covers T-162 and T-176; T-170 comes earlier in the same chain.
- `VideoPipeline.swift` is also edited by T-176.
- `EncoderKnobs.swift` is also edited by T-186 (later) and possibly T-178.

Wire: none.

## Kapsam dışı

- Any controller that decides *when* to change the bitrate (T-195, T-196).
- The `STREAM_PREFS` restart path and PROTOCOL §0x03/§0x05 semantics.
- Making a short-window `DataRateLimits` the default.

## Kabul kriterleri

- [ ] [XCTest] Rate-request value type: values clamp to `[floor, ceiling]`, equal consecutive values are deduplicated, and a request after `stop` is rejected.
- [ ] [XCTest] Through the T-162 owner-queue seam with a fake backend: set-bitrate calls are ordered with submits, and none reaches the backend after invalidate. Deterministic, with no sleeps.
- [ ] [XCTest] Step-knob parser: absent or invalid means off, and the valid form is parsed. Defaults are unchanged.
- [ ] [doc] `docs/LOGGING.md` lists `video ev=bitrate_set` with its fields.
- [ ] [device] With the step knob 60→15→60 Mbps on a scrolling page, the per-second bytes in host `net ev=stats` follow each step within ≤1 s. No video reconnect, no `STREAM_CONFIG`, no new `config_id` and no `restartPipeline` appear in the log. The `VTSessionSetProperty` status codes are recorded in Handoff and docs/NOTES.md (orchestrator).
- [ ] [device] Same check with `MATEBRIDGE_QUALITY` set: record whether frame sizes react (only `DataRateLimits` is set in that mode).
- [ ] [device] Short-window `DataRateLimits` pair: accepted or refused (status), plus the largest frame size (`idr_bytes_max`/frame p99) with and without it, recorded in NOTES.
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
