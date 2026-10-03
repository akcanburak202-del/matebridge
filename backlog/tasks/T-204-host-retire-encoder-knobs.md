---
id: T-204
title: Retire concluded host encoder experiments (idle refresh, …); add host `ev=profile`
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-182, T-177, T-145]
decisions: [0026]
files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift
  - host-mac/Sources/MateBridgeCore/Video/InputColorTags.swift
  - host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift
  - host-mac/Sources/MateBridgeCore/Video/SharpnessBenchOptions.swift
  - host-mac/Sources/MateBridgeHost/Video/SharpnessBench.swift
  - host-mac/Sources/MateBridgeHost/Video/EncodeBench.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoDump.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/EncoderKnobsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/IdleRefreshRefineTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/ExperimentKnobTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/InputColorTagsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/CadenceTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/EncodeBenchTests.swift
  - backlog/tasks/T-204-host-retire-encoder-knobs.md
---

## Amaç

The host encoder still carries the idle-refresh machinery. On the real path it produced 222-byte skip frames, and when enabled it adds a third (timer) caller into the encoder. A few dead switches remain too: `FRAME_DELAY`, `PRIO_SPEED=0`, `H264_PROFILE`, `INPUT_RETAG=0`. Removing them shrinks the encoder surface that the M02 fix (T-162) has to keep ordered. One `ev=profile` line per stream start then says exactly which configuration a log came from.

This card is the encoder half of the original T-186, split off on 2026-10-03 (QA-3). T-186 keeps the `nw` socket retirement.

Source: external architecture review 2026-10-03 (L02, D8); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-H1, L02 inventory rows 25, 27, 29, 30, 32).
Decision 0026 must be accepted by the user before work starts.

## Bağlam

**What goes** (row numbers from the T-182 inventory / `docs/KNOBS.md`):
- **Idle refresh** (row 29, T-086/T-087; NOTES.md:566-581):
  - `IdleRefreshBuffer`/`IdleRefreshConfig`/`RefreshQPBoost`/`IdleRefreshPolicy` and `MATEBRIDGE_IDLE_REFRESH_*` (`EncoderKnobs.swift:34-90`, `:111ff`, `:208ff`);
  - in `HEVCEncoder.swift`: the refresh timer `matebridge.encoder.refresh` (`:205-213`), the QP boost and copy pool (`:79-86`, `:124-128`, `:430-472`), the `idle_refresh_qp` warning (`:220-223`) and the `refresh:` branch of `resubmitLast` (`:338-346`);
  - **do not confuse** the refresh timer with the idle *keyframe* timer `matebridge.encoder.idle` (`:198-203`, `idleTick`). That one re-encodes the last buffer for a pending keyframe request on a static screen, and it stays;
  - the bench `--refresh-buffer` option (`SharpnessBenchOptions.swift`) and the idle-refresh plumbing in `host-mac/Sources/MateBridgeHost/Video/SharpnessBench.swift`;
  - `IdleRefreshRefineTests`.
  - **Keep `resubmitLast`** itself: it is the static-screen keyframe path (`requestKeyframe(resubmitNow:)`, `:307-310`).
- **`MATEBRIDGE_FRAME_DELAY`** (row 27, never measured or adopted):
  - `VideoSettings.swift:18-19`, `:52-56`, `:86`; `HEVCEncoder.swift:164-166`;
  - the `parseFrameDelay` cases in `CadenceTests.swift:93-95`;
  - the `--frame-delay` option of `--dump-video` (`host-mac/Sources/MateBridgeHost/Video/VideoDump.swift:4`, `:14`, `:39-41`, `:55`), which sets `settings.maxFrameDelayCount`. Remove the option together with the field, or the build breaks.
- **`MATEBRIDGE_PRIO_SPEED=0`** (row 30): `EncoderKnobs.swift:164`. `HEVCEncoder.swift:188-189` stays as a constant `true`. `MATEBRIDGE_QUALITY` stays (debug-only).
- **`MATEBRIDGE_H264_PROFILE`** (row 25): `EncoderKnobs.swift:3-13`, `:166`; Core `EncodeBench.swift:95-99`; `SharpnessBenchOptions.swift`. The H.264 profile becomes a constant (today's default `.high`). `MATEBRIDGE_CODEC` stays (debug-only).
- **`MATEBRIDGE_INPUT_RETAG=0`** (row 32, T-113; NOTES.md:777-806): retag is always on (`InputColorTags.swift:36-38`; `EncoderKnobs.swift:153-163`; bench options in Core `EncodeBench.swift:99-101`).

**What stays:** every knob classed debug-only or keep in 0026, for example `MATEBRIDGE_FPS`, `BITRATE_KBPS`, `CODEC`, `REFRESH`, `ENCODER`, `QUALITY`, `KEYFRAME_INTERVAL_S`, `WIFI_BITRATE_KBPS`, `SERVICE_CLASS`, `NOTSENT_LOWAT_KB`, `AUDIO`, `SENDQ_LOG`, `LAT_TRACE`, `TCP_LOG`, the 4 CLI modes, and T-177's step knob.

**Stale comment outside `files:`:** `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:182-184` names `MATEBRIDGE_FRAME_DELAY=0|1` in a comment. Do not edit it here, because that file is on the T-165 → T-167 → T-187 → T-196 → T-200 chain. Write it under *Açık sorular*, so the next card that edits `StreamCoordinator.swift` drops the stale knob name.

**`ev=profile`** (one line per stream start, next to `encoder_config` in `HEVCEncoder.swift:216-219`):
- fields: fps, bitrate and `bitrate_source`, codec, encoder profile, and the non-default `MATEBRIDGE_*` env knobs (names and values; no paths or identities);
- the knob list is an allow-list of the keep and debug-only host env knobs in 0026. A removed key such as `MATEBRIDGE_IDLE_REFRESH_MS` is never listed. The socket knobs `MATEBRIDGE_VIDEO_SOCKET`/`MATEBRIDGE_CONTROL_SOCKET` are not in the allow-list: the `listening` line already reports the sockets, and T-186 retires the `nw` choice;
- `sha=` from T-145's `BuildInfo` (`host-mac/Sources/MateBridgeCore/Session/BuildInfo.swift`, created by T-145, a dependency). Read it; do not duplicate it;
- put the pure field builder in `EncoderKnobs.swift`, with an XCTest;
- write the `ev=profile` LOGGING text under *Açık sorular* for the orchestrator (`docs/LOGGING.md` is not in `files:`).

**Serialization:**
- `HEVCEncoder.swift` chain: T-162 → T-170 → T-176 → T-177 → T-204 → T-187. T-177 is a dependency, and T-187 depends on this card.
- `VideoSettings.swift`/`EncoderKnobs.swift`: **serialize with T-178 (same files)**. T-178 is gated on T-127 and is not a dependency. T-177 (also `EncoderKnobs.swift`) is a dependency.
- `SharpnessBench.swift`: T-201 comes after this card (it depends on T-204).
- The test files above sit in `host-mac/Tests/MateBridgeCoreTests/Video/`, which T-170, T-176, T-177, T-178, T-187, T-192 and T-196 also list. **Serialize with T-178, T-192 and T-196 (same directory)**. T-170, T-176 and T-177 come earlier on the dependency chain, and T-187 comes later.
- No shared files with T-186 (the `nw` half). The two can run in parallel.
- If 0026 is accepted before T-162 starts, the orchestrator may run this card first, because the audit prefers shrinking the surface first. The card then drops T-177 from `depends_on` and T-162 rebases. The default order is the safety fix first.

Wire: none.

## Kapsam dışı

- Changing any default.
- The `nw` sockets (T-186).
- H03 bitrate work (T-177/T-178/T-196).
- Moving the CLI modes to a separate executable.

## Kabul kriterleri

- [ ] [XCTest] The parsers and tests for the removed keys are gone: `IdleRefreshRefineTests`, and the `FRAME_DELAY`, `PRIO_SPEED`, `H264_PROFILE` and `INPUT_RETAG` cases. The remaining knob tests pass: `EncoderKnobsTests`, `ExperimentKnobTests`, `InputColorTagsTests`, `CadenceTests` and `EncodeBenchTests`.
- [ ] [XCTest] The `ev=profile` field builder:
  - with an empty env it lists no knobs;
  - with e.g. `MATEBRIDGE_BITRATE_KBPS=40000` it lists that knob;
  - a removed key such as `MATEBRIDGE_IDLE_REFRESH_MS` is ignored;
  - the output contains `sha=` from `BuildInfo`.
- [ ] [XCTest] A grep in Handoff shows no `MATEBRIDGE_IDLE_REFRESH_*`, `FRAME_DELAY`, `maxFrameDelayCount`, `PRIO_SPEED`, `H264_PROFILE` or `INPUT_RETAG` in Sources **code**. Comments are exempt; list every remaining comment hit (at least `StreamCoordinator.swift:182-184`) in Handoff. `--dump-video` no longer accepts `--frame-delay`.
- [ ] [device] USB and Wi-Fi sessions stream. The `profile` line is present once per stream start, and its `sha=` equals T-145's `app_start`.
- [ ] [device] A static screen still receives a keyframe after reconnect (`resubmitLast` path): no black screen after 10 reconnects.
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
