---
id: T-187
title: Warn when VideoToolbox did not select the hardware encoder
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-204]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderHardwareCheck.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/LOGGING.md
  - backlog/tasks/T-187-host-encoder-hw-warning.md
---

## Amaç

The host asks VideoToolbox for the hardware encoder but does not require it. If VT ever falls back to a software encoder (for example when the media engine is busy, or after an OS update), latency and CPU would jump, and today the only trace is one field buried inside the `cadence_setup` line. After this card, a software or unknown encoder shows up as its own warning line and in the menu bar summary, so a slow session can be explained at a glance.

Source: external architecture review 2026-10-03 (PF7, D8); verification: docs/reviews/2026-10-03/verify-C-host-video.md (PF7-H).

## Bağlam

**Evidence at HEAD (a30c769):**
- The session is created with `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true` (`host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:138`). That is "Enable", not "Require". `RealTime=false` with the `.fast` profile is the default at every fps (`:130-137`, `:159`; T-047/T-053).
- `cadenceReadback()` already reads `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` through its local `read(_:)` helper (`:274-288`, `Hardware=` at `:287`).
- That string is logged once per pipeline start inside `ev=cadence_setup … encoder_read[… Hardware=…]`: `VideoPipeline.cadenceSetup` (`host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:165-170`) → `StreamCoordinator.swift:595-596`.
- `--encode-bench` checks the same property (`host-mac/Sources/MateBridgeHost/Video/EncodeBench.swift:165`).
- Nothing acts on the value: no warning level, no menu text, no counter.
- **Do NOT switch to `RequireHardwareAcceleratedVideoEncoder`.** NOTES (T-046 entry, ~l.272) shows the media engine being shared with a bench. Require would turn transient contention into a failed pipeline. A warning plus measurement is safer.

**Design hints:**
- Expose `usingHardware: Bool?` from `HEVCEncoder`, reusing the `read(_:)` logic. `nil` means unreadable (non-`noErr` status or a missing value).
- Pure Core mapping (`EncoderHardwareCheck.swift`): `true` → info `ev=encoder_hw using_hw=1`; `false` → warning `using_hw=0`; `nil` → warning `using_hw=unknown status=<OSStatus>`. Also produce the short menu text ("yazılım kodlayıcı" / "software encoder"; pick the Turkish UI wording used elsewhere in the menu).
- Log it from the pipeline-creation path next to `cadence_setup` (`StreamCoordinator.swift:595-596`), exactly once per pipeline.
- **Menu:** `StreamCoordinator.onSummary` is overwritten about once a second by `publishSummary` (`StreamCoordinator.swift:496-499`: `lastStatsText · lastCadenceText`), and `display_created` clears it (`:597`). Keep the warning in a field that `publishSummary` includes, for example appended to the summary while the current pipeline's flag is false or unknown. Then it neither flickers nor disappears. `HA/main.swift` shows `onSummary` as-is (`main.swift:163`) and needs no change.
- The client decoder half (`is_hw=` / `sw_only=`) is in T-168, not here.

**Serialization:**
- `HEVCEncoder.swift` chain: … T-177 → T-204 → T-187 (T-204 is the dependency; it took over the encoder half of T-186).
- `StreamCoordinator.swift` chain: T-165 → T-167 → T-187 → T-196 → T-200. Serialize with T-165 and T-167 (same file, not dependencies).
- `VideoPipeline.swift` is also edited by T-176/T-177 (earlier via the dependency chain).

Wire: none.

## Kapsam dışı

- Changing the encoder specification (no `Require`).
- The client decoder check (T-168).
- Any automatic fallback or restart on a software encoder.

## Kabul kriterleri

- [x] [XCTest] Mapping `true` / `false` / unreadable (with status) → log level, `using_hw=1|0|unknown` fields and menu text.
- [x] [doc] `docs/LOGGING.md` lists `video ev=encoder_hw using_hw=1|0|unknown [status=]` and when it is logged.
- [ ] [device] A normal start logs exactly one `ev=encoder_hw using_hw=1` per pipeline (check across 5 `STREAM_PREFS` changes = 6 pipelines), and the menu shows no warning.
- [ ] [device] Optional: forcing a software path (e.g. an unsupported size through `--encode-bench`, or `MATEBRIDGE_CODEC=h264` at 2800×1840 @120 if VT falls back) logs the warning, and the menu shows the software-encoder text. If no software path can be forced, say so in Handoff.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Core** `EncoderHardwareCheck.swift`: `enum EncoderHardwareCheck { hardware, software, unknown(status: Int32) }`, `init(usingHardware: Bool?, status: Int32)`, `logLevel` (info / warning / warning), `logFields` (`using_hw=1|0|unknown status=<n>`), `menuText` (`nil` / `yazılım kodlayıcı` / `kodlayıcı türü bilinmiyor`), `event = "encoder_hw"`.
2. **XCTest** `Tests/MateBridgeCoreTests/Video/EncoderHardwareCheckTests.swift`: the three mappings + `status=0` (noErr but missing value).
3. **HEVCEncoder**: shared `copyProperty(_:)` helper behind both `read(_:)` helpers; new `hardwareCheck() -> EncoderHardwareCheck` (reads `UsingHardwareAcceleratedVideoEncoder`, `as? Bool`; closed session → `unknown(kVTInvalidSessionErr)`). Encoder spec unchanged (Enable, not Require).
4. **VideoPipeline**: `encoderHardware: EncoderHardwareCheck` (`unknown(kVTInvalidSessionErr)` without encoder; was planned as optional, made non-optional during implementation).
5. **StreamCoordinator**: in `createPipeline` after `cadence_setup`, read once, log `video ev=encoder_hw`, remember `(pipelineID, check)`. `publishSummary` appends the menu text while the current pipeline (`pipeline != nil`, same id) is software/unknown; `createPipeline`'s `onSummary("")` becomes `onSummary(warning ?? "")`. Drop the stale `MATEBRIDGE_FRAME_DELAY` comment (T-204).
6. **LOGGING.md**: new separate section `Kodlayıcı donanım denetimi (Mac, video, T-187)`.
- Risk: the property is read on the event loop (one `VTSessionCopyProperty`, cheap, already done by `cadence_setup`).

## Handoff

- **Commit:** `49ac6c8` (implementation; plan `f054219`, handoff commit on top). Branch `task/T-187-host-encoder-hw-warning`. `./scripts/check.sh`: ALL OK (6 new `EncoderHardwareCheckTests`).
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/EncoderHardwareCheck.swift` (new): `hardware|software|unknown(status:)`, `logLevel`, `logFields`, `menuText`, `event = "encoder_hw"`.
  - `host-mac/Tests/MateBridgeCoreTests/Video/EncoderHardwareCheckTests.swift` (new).
  - `HEVCEncoder.swift`: `hardwareCheck()`, `noSessionStatus = kVTInvalidSessionErr`; the two local `read(_:)` copies in `cadenceReadback`/`colorReadback` became one private `read(_:)` over a shared `copyProperty(_:)` (output unchanged). Encoder spec unchanged (`Enable…`, not `Require…`).
  - `VideoPipeline.swift`: `encoderHardware` (reads the property on each call).
  - `StreamCoordinator.swift`: `createPipeline` logs `video ev=encoder_hw` once right after `cadence_setup` and stores `(pipelineID, check)`; `publishSummary` appends the menu text while that pipeline is current; `createPipeline`'s `onSummary("")` is now `onSummary(warning ?? "")`. Stale `MATEBRIDGE_FRAME_DELAY` comment removed (T-204).
  - `docs/LOGGING.md`: new separate section "Kodlayıcı donanım denetimi (Mac, `video`, T-187)" at the end.
- **Varsayımlar:**
  - Menu wording: `yazılım kodlayıcı` (software) and `kodlayıcı türü bilinmiyor` (unreadable), lowercase like `yak→çöz` in the summary, joined with ` · `.
  - The warning is tied to the pipeline, not the session: it disappears when the pipeline is stopped, parked, failed or replaced (`pipeline != nil` and same `pipelineID`). `display_created` no longer blanks a software warning; for hardware it still sends `""` as before.
  - `using_hw=unknown status=0` means `VTSessionCopyProperty` returned `noErr` but no boolean value.
  - `EncodeBench.swift` (`--encode-bench`) was not changed (outside `files:`); it still prints its own `Hardware=` read.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - [device] One normal session plus 5 `STREAM_PREFS` changes → exactly 6 `I video ev=encoder_hw using_hw=1` lines, each right after a `cadence_setup`; the menu summary shows no warning.
  - [device] Also once after a park/unpark (reconnect within `DISPLAY_KEEP_S`) and after a `pipeline_retry`: one line per new pipeline.
  - [device, optional] Software path: not tried (no GUI and no device in this run). Candidates: `MATEBRIDGE_CODEC=h264` at 2800×1840 @120. If the line says `using_hw=0`, the menu should show `… · yazılım kodlayıcı`, and it should survive the 1 s summary refresh. Whether any software path can be forced on M6 is still open.
- **Açık sorular:**
  - `--encode-bench` could reuse `EncoderHardwareCheck` for its `Hardware=` line, but `EncodeBench.swift` is not in `files:`. Left as is.
