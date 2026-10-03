---
id: T-186
title: Retire concluded host experiments (`nw` sockets, idle refresh, …); add `ev=profile`
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-182, T-177, T-171, T-145]
decisions: [0026]
files:
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift
  - host-mac/Sources/MateBridgeCore/Video/InputColorTags.swift
  - host-mac/Sources/MateBridgeCore/Video/EncodeBench.swift
  - host-mac/Sources/MateBridgeCore/Video/SharpnessBenchOptions.swift
  - host-mac/Sources/MateBridgeHost/Video/SharpnessBench.swift
  - host-mac/Sources/MateBridgeHost/Video/EncodeBench.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/EncoderKnobsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/IdleRefreshRefineTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/ExperimentKnobTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/InputColorTagsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/CadenceTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/EncodeBenchTests.swift
  - backlog/tasks/T-186-host-retire-experiments.md
---

## Amaç

The host still carries two complete experiment stacks that lost:
- the Network.framework (`nw`) control and video sockets, with a ~27 Mbps Wi-Fi ceiling and 4 % retransmits; `bsd` is the default on both;
- the idle-refresh machinery, which produced 222-byte skip frames on the real path and, when enabled, adds a third (timer) caller into the encoder.

A few dead switches remain too: `FRAME_DELAY`, `PRIO_SPEED=0`, `H264_PROFILE`, `INPUT_RETAG=0`. Removing them shrinks `SessionServer` (1,805 lines) and the encoder surface the M02 fix (T-162) has to keep ordered. One `ev=profile` line per stream start then says exactly which configuration a log came from.

Source: external architecture review 2026-10-03 (L02, D8); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-H1, L02 inventory rows 25, 27, 29, 30, 32, 35).
Decision 0026 must be accepted by the user before work starts, including the user's explicit confirmation of the `nw` retirement (T-182).

## Bağlam

**What goes** (row numbers from the T-182 inventory / `docs/KNOBS.md`):
- **`nw` sockets** (row 35, T-091/T-092/T-111; NOTES.md:620-631):
  - `MATEBRIDGE_VIDEO_SOCKET`/`MATEBRIDGE_CONTROL_SOCKET` parsing (`host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift:79-95`, `:138-153`);
  - in `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`: `import Network` (`:3`), the `NWConnection` video link case (`:34-38`, `:112-115`), the listener/connection enums (`:336-375`), `bonjourService()` (`:561-562`), the `nw` video listener (`:600`), `videoListenerState` (`:955`), the `nw` control listener (`:987`), and `accept`/`receiveLoop` for `NWConnection` (`:1125`, `:1205`);
  - the `NWConnection` variant of `host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift` (`:29`, `:42`, `:103`, `:176`, `:221`).
- **Idle refresh** (row 29, T-086/T-087; NOTES.md:566-581):
  - `IdleRefreshBuffer`/`IdleRefreshConfig`/`RefreshQPBoost`/`IdleRefreshPolicy` and `MATEBRIDGE_IDLE_REFRESH_*` (`EncoderKnobs.swift:34-90`, `:111ff`, `:208ff`);
  - in `HEVCEncoder.swift`: the refresh timer `matebridge.encoder.refresh` (`:205-213`), QP boost and copy pool (`:79-86`, `:124-128`, `:430-472`) and the `refresh:` branch of `resubmitLast` (`:338-346`);
  - **Do not confuse** the refresh timer with the idle *keyframe* timer `matebridge.encoder.idle` (`:198-203`, `idleTick`). That one re-encodes the last buffer for a pending keyframe request on a static screen, and it stays;
  - the bench `--refresh-buffer` option (`SharpnessBenchOptions.swift`);
  - `IdleRefreshRefineTests`.
  - **Keep `resubmitLast`** itself: it is the static-screen keyframe path (`requestKeyframe(resubmitNow:)`, `:307-310`).
- **`MATEBRIDGE_FRAME_DELAY`** (row 27, never measured or adopted): `VideoSettings.swift:18-19`, `:52-56`, `:86`; `HEVCEncoder.swift:164-166`; the `parseFrameDelay` cases in `CadenceTests.swift:93-95`.
- **`MATEBRIDGE_PRIO_SPEED=0`** (row 30): `EncoderKnobs.swift:164`; `HEVCEncoder.swift:188-189` stays as a constant `true`. `MATEBRIDGE_QUALITY` stays (debug-only).
- **`MATEBRIDGE_H264_PROFILE`** (row 25): `EncoderKnobs.swift:3-13`, `:166`; Core `EncodeBench.swift:95-99`; `SharpnessBenchOptions.swift`. The H.264 profile becomes a constant (today's default `.high`). `MATEBRIDGE_CODEC` stays (debug-only).
- **`MATEBRIDGE_INPUT_RETAG=0`** (row 32, T-113; NOTES.md:777-806): retag is always on (`InputColorTags.swift:36-38`; `EncoderKnobs.swift:153-163`; bench options in Core `EncodeBench.swift:99-101`).

**What stays:** every knob classed debug-only or keep in 0026, for example `MATEBRIDGE_FPS`, `BITRATE_KBPS`, `CODEC`, `REFRESH`, `ENCODER`, `QUALITY`, `KEYFRAME_INTERVAL_S`, `WIFI_BITRATE_KBPS`, `SERVICE_CLASS`, `NOTSENT_LOWAT_KB`, `AUDIO`, `SENDQ_LOG`, `LAT_TRACE`, `TCP_LOG`, the 4 CLI modes, and T-177's step knob.

**Bonjour:** the kernel-socket control listener registers through `BonjourAdvertiser` (`SessionServer.swift:227-228`, `:1075-1084`). Make sure that remains the only path, and that the TXT `wol=` update (T-128) still works. A WI-5's USB-only hints (`:600`/`:987`) become obsolete with this card; T-189 binds loopback on the `bsd` path afterwards.

**`ev=profile`** (one line per stream start, next to `encoder_config` in `HEVCEncoder.swift:216-219`):
- fields: fps, bitrate and `bitrate_source`, codec, encoder profile, and the non-default `MATEBRIDGE_*` env knobs (names and values; no paths or identities);
- `sha=` from T-145's `BuildInfo` (`host-mac/Sources/MateBridgeCore/Session/BuildInfo.swift`). T-145 (D1) is not in `depends_on`. If it has not merged, stop and write that under *Açık sorular* rather than duplicating BuildInfo;
- put the pure field builder in `EncoderKnobs.swift` or `TransportKnobs.swift` (both in `files:`), with an XCTest.
- The `listening` line (`SessionServer.swift:1068-1071`) loses its `video_socket=`/`control_socket=` fields, or keeps them as constants. Pick one and write the LOGGING text under *Açık sorular* for the orchestrator.

**Serialization:**
- `HEVCEncoder.swift` chain T-162 → T-170 → T-176 → T-177 → T-186 → T-187.
- `SessionServer.swift` chain T-163 → T-171 → T-186 → T-189 → T-196.
- `VideoSettings.swift`/`EncoderKnobs.swift`: serialize with T-178 (same files; T-178 is gated on T-127 and not a dependency).
- If 0026 is accepted before T-162 starts, the orchestrator may run this card's encoder part first (the audit prefers shrinking the surface first). The default order is safety fix first.

Wire: none.

## Kapsam dışı

- Changing any default.
- H03 bitrate work (T-177/T-178/T-196); the USB-only profile (T-189).
- Moving the CLI modes to a separate executable.

## Kabul kriterleri

- [ ] [XCTest] The parsers and tests for the removed keys are gone (`IdleRefreshRefineTests` and the `nw`, `FRAME_DELAY`, `PRIO_SPEED`, `H264_PROFILE` and `INPUT_RETAG` cases). The remaining knob tests pass: `TransportKnobsTests`, `EncoderKnobsTests`, `ExperimentKnobTests`, `InputColorTagsTests`, `CadenceTests`, `EncodeBenchTests`.
- [ ] [XCTest] `ControlSocketTests` and `BsdTcpSocketTests` pass unchanged.
- [ ] [XCTest] The `ev=profile` field builder: with an empty env it lists no knobs; with e.g. `MATEBRIDGE_BITRATE_KBPS=40000` it lists that knob; a removed key such as `MATEBRIDGE_IDLE_REFRESH_MS` is ignored.
- [ ] [XCTest] A grep in Handoff shows no `import Network`, `NWListener` or `NWConnection` left in `MateBridgeHost/Session/`, and no `MATEBRIDGE_IDLE_REFRESH_*`, `FRAME_DELAY`, `PRIO_SPEED`, `H264_PROFILE` or `INPUT_RETAG` in Sources. Comments in `BonjourAdvertiser.swift` and `TransportKnobs.swift` that only mention Network.framework historically may stay.
- [ ] [device] USB and Wi-Fi sessions connect. Bonjour discovery works from the tablet. The Bonjour TXT `wol=` updates (T-128 check). The `listening` and `profile` lines are present, and `profile` shows `sha=` equal to T-145's `app_start`.
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
