---
id: T-204
title: Retire concluded host encoder experiments (idle refresh, …); add host `ev=profile`
status: done
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

- [x] [XCTest] The parsers and tests for the removed keys are gone: `IdleRefreshRefineTests`, and the `FRAME_DELAY`, `PRIO_SPEED`, `H264_PROFILE` and `INPUT_RETAG` cases. The remaining knob tests pass: `EncoderKnobsTests`, `ExperimentKnobTests`, `InputColorTagsTests`, `CadenceTests` and `EncodeBenchTests`.
- [x] [XCTest] The `ev=profile` field builder:
  - with an empty env it lists no knobs;
  - with e.g. `MATEBRIDGE_BITRATE_KBPS=40000` it lists that knob;
  - a removed key such as `MATEBRIDGE_IDLE_REFRESH_MS` is ignored;
  - the output contains `sha=` from `BuildInfo`.
- [x] [XCTest] A grep in Handoff shows no `MATEBRIDGE_IDLE_REFRESH_*`, `FRAME_DELAY`, `maxFrameDelayCount`, `PRIO_SPEED`, `H264_PROFILE` or `INPUT_RETAG` in Sources **code**. Comments are exempt; list every remaining comment hit (at least `StreamCoordinator.swift:182-184`) in Handoff. `--dump-video` no longer accepts `--frame-delay`.
- [ ] [device] USB and Wi-Fi sessions stream. The `profile` line is present once per stream start, and its `sha=` equals T-145's `app_start`.
- [ ] [device] A static screen still receives a keyframe after reconnect (`resubmitLast` path): no black screen after 10 reconnects.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Core `EncoderKnobs.swift`:** delete `H264Profile`, `IdleRefreshBuffer`, `IdleRefreshConfig`, `RefreshQPBoost`, `IdleRefreshPolicy`; drop `prioritizeSpeed`, `h264Profile`, `idleRefresh`, `retagInput` from `EncoderKnobs` and their env reads. `logFields` keeps `prio_speed=1 … idle_refresh=off input_retag=1` as constants (T-186 precedent: parsers and `LiveBitrateTests`, outside `files:`, stay unchanged). Add the pure `StreamProfileLog` builder (allow-list of the 0026 keep/debug-only host env keys, sanitised values, `sha=` from `BuildInfo`).
2. **`VideoSettings.swift`:** delete `maxFrameDelayCount`, `parseFrameDelay` and the `MATEBRIDGE_FRAME_DELAY` read. **`VideoDump.swift`:** delete `--frame-delay`.
3. **`InputColorTags.swift`:** delete `InputRetag.isEnabled`; retag is unconditional.
4. **Core `EncodeBench.swift`:** delete `h264Profile`/`retagInput` options and their env reads. **Host `EncodeBench.swift`:** constant H.264 High profile, always retag. The bench matrix's `prioritizeSpeed` config field (`no-prioritize`) is a bench config, not the env knob, and stays.
5. **`SharpnessBenchOptions.swift`/`SharpnessBench.swift`:** delete `--refresh-buffer` and `effectiveStaticMs`; frames not matched to a source are reported as `phase=resubmit`.
6. **`HEVCEncoder.swift`:** delete the refresh timer, `IdleRefreshPolicy`, QP boost, copy pool, `Input.refresh`, the `idle_refresh_qp` warning and `resubmitLast(refresh:)`. Keep the idle keyframe timer and `resubmitLast()`. Set `PrioritizeEncodingSpeedOverQuality=true`, H.264 `High_AutoLevel` and the input retag as constants. Log `ev=profile` once after `encoder_config`.
7. **Tests:** delete `IdleRefreshRefineTests.swift` and the removed-key cases; add the `StreamProfileLog` tests.
- **Risks:** the T-162 owner-queue ordering and the T-177 setter must stay unchanged, so only call sites are removed. `resubmitLast` stays on the idle-keyframe and `requestKeyframe(resubmitNow:)` paths.

## Handoff

- **Commit:** `7fb4c99` (code, on top of plan commit `582949f`) on `task/T-204-host-retire-encoder-knobs`. `./scripts/check.sh`: ALL OK.
- **Dokunulan dosyalar:** all in `files:`.
  - Core: `EncoderKnobs.swift`, `VideoSettings.swift`, `InputColorTags.swift`, `EncodeBench.swift`, `SharpnessBenchOptions.swift`.
  - Host: `HEVCEncoder.swift`, `EncodeBench.swift`, `SharpnessBench.swift`, `VideoDump.swift`.
  - Tests: `EncoderKnobsTests.swift`, `InputColorTagsTests.swift`, `CadenceTests.swift`, `EncodeBenchTests.swift`. `IdleRefreshRefineTests.swift` is deleted. `ExperimentKnobTests.swift` needed no change.
  - This card.
- **What was removed:**
  - `H264Profile`, `IdleRefreshBuffer`, `IdleRefreshConfig`, `RefreshQPBoost`, `IdleRefreshPolicy`.
  - `EncoderKnobs.prioritizeSpeed`/`h264Profile`/`idleRefresh`/`retagInput`.
  - `VideoSettings.maxFrameDelayCount`/`parseFrameDelay`.
  - `InputRetag.isEnabled`.
  - `EncodeBenchOptions.h264Profile`/`retagInput`.
  - `SharpnessBenchOptions.refreshBuffer`/`effectiveStaticMs`.
  - `--dump-video --frame-delay`.
  - In the encoder: the refresh timer `matebridge.encoder.refresh`, the QP boost, the copy pool, `Input.refresh`, the `idle_refresh_qp` warning and the `refresh:` branch of `resubmitLast`.
  - **Kept:** the idle keyframe timer `matebridge.encoder.idle`/`idleTick`, `resubmitLast()` (now parameterless), `requestKeyframe(resubmitNow:)`, the T-162 owner queue and the T-170 `resubmit` trace flag. The T-177 setter, `BITRATE_STEP` and `RATE_WINDOW_MS` are untouched.
  - `PrioritizeEncodingSpeedOverQuality=true`, H.264 `High_AutoLevel` and the input retag are constants.
- **`ev=profile`:**
  - The pure builder `StreamProfileLog` is in `EncoderKnobs.swift`. The encoder logs it with `logSink(.info, "profile", …)` right after `encoder_config`, so it goes to `host.log` component `encoder`; the benches print it.
  - It is logged once per `HEVCEncoder` init, which is once per `VideoPipeline.start` (`VideoPipeline.swift:95`).
  - `sha=` comes from `BuildInfo(infoDictionary: Bundle.main.infoDictionary)`, the same source as `app_start` (static, read once).
  - Example: `fps=60 bitrate_kbps=30000 bitrate_source=prefs codec=hevc encoder_profile=fast scale_permille=1000 refresh_hz=60 sha=65dc662-dirty knobs=-`.
- **Acceptance grep** (`grep -rnE "MATEBRIDGE_IDLE_REFRESH|FRAME_DELAY|maxFrameDelayCount|PRIO_SPEED|H264_PROFILE|INPUT_RETAG|frame-delay|refresh-buffer" host-mac/Sources`, at 7fb4c99): **no code hits**. Comment hits:
  - `Sources/MateBridgeHost/Session/StreamCoordinator.swift:196`: stale `MATEBRIDGE_FRAME_DELAY=0|1` (was :182-184 at ef264dd). Not my file, see open questions.
  - `Sources/MateBridgeHost/Video/SharpnessBench.swift:18`: "T-204 removed … `--refresh-buffer`".
  - `Sources/MateBridgeHost/Video/HEVCEncoder.swift:207` (PRIO_SPEED retired) and `:263` (H264_PROFILE retired).
  - `Sources/MateBridgeCore/Video/SharpnessBenchOptions.swift:5` (`--refresh-buffer` removed).
  - `Sources/MateBridgeCore/Video/EncoderKnobs.swift:64-65` and `:120` (retired keys named in doc comments).
  - The encoder's `cadenceReadback()` still reads the VT property `MaxFrameDelayCount`. That is a diagnostic readback of the encoder default (capital M, so it does not match the grep), not the knob.
- **Varsayımlar:**
  - "Non-default knob" means the knob is set in the environment. Its raw value is listed even when it equals the default or is invalid; the effective values are in the `fps`/`bitrate_kbps`/`codec`/`encoder_profile` fields.
  - Values are made into one token: whitespace, `=` and `;` become `_`, at most 64 characters, an empty value becomes `_`. The format is `NAME:value` joined by `;` (`BITRATE_STEP` values contain commas, so `,` cannot be the separator).
  - Allow-list (KNOBS rows 24, 25 CODEC, 26, 28, 30 QUALITY, 31, 33, 34, 36-42): `FPS, BITRATE_KBPS, WIFI_BITRATE_KBPS, CODEC, REFRESH, ENCODER, QUALITY, KEYFRAME_INTERVAL_S, BITRATE_STEP, RATE_WINDOW_MS, SERVICE_CLASS, NOTSENT_LOWAT_KB, SENDQ_LOG, LAT_TRACE, TCP_LOG, AUDIO, DISPLAY_KEEP_S` (all `MATEBRIDGE_`-prefixed). The socket knobs are excluded, as the card requires.
  - `scale_permille=` and `refresh_hz=` were added beyond the card's minimum list, because 0026 §4 asks for the scale.
  - `ev=encoder_config` keeps `prio_speed=1 idle_refresh=off input_retag=1` as **constants** (T-186 `video_socket=bsd` precedent). This keeps parsers stable and keeps `LiveBitrateTests.swift` (outside `files:`) unchanged.
  - `--dump-video --frame-delay` and `--sharpness-bench --refresh-buffer` are now ignored like any unknown argument (both parsers skip unknown flags), not rejected. `--sharpness-bench` labels frames not made from a scrolled source as `phase=resubmit` (was `idle_refresh`) and prints `static_end … resubmits=N`.
  - The bench configs `no-prioritize`/`nolat-rtoff-noprio` stay: they are bench-matrix entries, not the env knob. The encode bench always retags (the default before too) and still prints `input_retag=1` and, for H.264, `profile=high`.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - [device] USB and Wi-Fi sessions stream. `host.log` has exactly one `encoder ev=profile` per stream start (and one per STREAM_PREFS restart, since that recreates the encoder). Its `sha=` equals `session ev=app_start sha=` (bundled build only; `swift run` gives `unknown`).
  - [device] Static screen: 10 reconnects and no black screen (idle keyframe → `resubmitLast()` path). Also check that `latency.csv` rows with `resubmit=1` still appear on a static screen with `MATEBRIDGE_LAT_TRACE=1`.
  - [device, optional] `MATEBRIDGE_BITRATE_KBPS=40000` gives `knobs=MATEBRIDGE_BITRATE_KBPS:40000 bitrate_source=env`. `MATEBRIDGE_IDLE_REFRESH_MS=300` gives no `idle_refresh` lines and no knob in `profile`.
  - [device, optional] `MATEBRIDGE_CODEC=h264` still opens (`encoder_config … profile=high`).
  - Not run: `--sharpness-bench`, `--encode-bench`, `--dump-video` (the no-GUI rule applies; dump-video creates a virtual display). They build and their option parsers are unit-tested.
- **Açık sorular:**
  1. **Stale comment:** `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:196` still says `MATEBRIDGE_FRAME_DELAY=0|1`. The next card that edits `StreamCoordinator.swift` (T-165 → T-167 → T-187 → T-196 → T-200 chain) should drop that knob name.
  2. **`docs/LOGGING.md` text** (suggested; for example a new section after "Canlı bit hızı"):

     ```markdown
     ## Akış profili (Mac, `encoder`, T-204)

     - `I encoder ev=profile fps=<n> bitrate_kbps=<n> bitrate_source=env|wifi_env|user|prefs codec=hevc|h264 encoder_profile=fast|llrc scale_permille=<n> refresh_hz=<n> sha=<kısa SHA>[-dirty]|unknown knobs=<AD:değer>[;…]|-`
      - Kodlayıcı her oluşturulduğunda bir kez yazılır: her akış başlangıcında ve her yeniden başlatmada (ör. `STREAM_PREFS`). Hemen `ev=encoder_config`'ten sonra gelir.
      - `sha=` `ev=app_start` ile aynı kaynaktan gelir (`BuildInfo`, T-145).
      - `knobs=` ortamda tanımlı olan host ayarlarını listeler. Yalnız karar 0026'da "kalır" ya da "yalnızca geliştirici" sınıfındakiler sayılır. Sıra: `FPS, BITRATE_KBPS, WIFI_BITRATE_KBPS, CODEC, REFRESH, ENCODER, QUALITY, KEYFRAME_INTERVAL_S, BITRATE_STEP, RATE_WINDOW_MS, SERVICE_CLASS, NOTSENT_LOWAT_KB, SENDQ_LOG, LAT_TRACE, TCP_LOG, AUDIO, DISPLAY_KEEP_S` (hepsi `MATEBRIDGE_` önekli).
      - Değer ham yazılır: boşluk, `=` ve `;` `_` olur, en çok 64 karakter. Varsayılana eşit ya da geçersiz değer de listelenir; etkin değerler önceki alanlardadır.
      - Kaldırılan ya da listede olmayan anahtarlar (ör. `MATEBRIDGE_IDLE_REFRESH_MS`, soket ayarları) hiç yazılmaz. Hiçbiri yoksa `knobs=-`.
     - `ev=encoder_config` satırındaki `prio_speed=1 idle_refresh=off input_retag=1` T-204'ten beri sabittir (ayarları kaldırıldı). Log ayrıştırıcıları kırılmasın diye kalır.
     - `ev=idle_refresh`, `ev=idle_refresh_copy` ve `ev=idle_refresh_qp` artık çıkmaz.
     ```
  3. **`docs/KNOBS.md`:**
     - Mark these rows' class as **"kaldırıldı (T-204, 2026-10-03)"**, as row 35 does: 25 (`H264_PROFILE` only; CODEC stays debug-only), 27, 29, 30 (`PRIO_SPEED` only; QUALITY stays) and 32.
     - Update the header count; these env vars are no longer read: `H264_PROFILE`, `FRAME_DELAY`, `IDLE_REFRESH_MS/_COUNT/_KEY/_BUFFER/_QP`, `PRIO_SPEED`, `INPUT_RETAG`.
     - Rows marked "T-204 (profil)" are done: those knobs appear in `ev=profile knobs=`.
     - Add to the intro: every new host env knob classed keep/debug-only must also be added to `StreamProfileLog.knobAllowList` (`EncoderKnobs.swift`). This includes anything T-189/T-178 add.
  4. If the orchestrator prefers to drop the constant `prio_speed`/`idle_refresh`/`input_retag` fields from `encoder_config`, then `Tests/MateBridgeCoreTests/Video/LiveBitrateTests.swift:69,102` (outside `files:`) must change too.
