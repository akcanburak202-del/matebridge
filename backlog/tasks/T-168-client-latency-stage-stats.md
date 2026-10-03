---
id: T-168
title: Break client latency into stages with percentiles; stop clamping; fix stats maps; log decoder hardware
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-161]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderCodec.kt   # diagnostic accessor only (is_hw / sw_only)
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderFault.kt   # diagnostic accessor only (delegate it)
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/IntervalHistogram.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/ClockSync.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/StatsFormat.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - docs/LOGGING.md
  - backlog/tasks/T-168-client-latency-stage-stats.md
---

## Amaç

The tablet's "Gecikme ~11 ms" (overlay, STATS and the Mac menu) measures only capture-stamp → decoder output, as a clamped mean. It leaves out the pacing stage (ready→slot 13–17 ms at 120 Hz), the release and the render callback, so it is mislabelled by roughly 2–4×. After this card every tablet number says what it measures, as p50/p95/p99/max per log window: capture→decode, ready→slot, capture→release and capture→render callback. Negative samples are counted instead of hidden, and the clock uncertainty is shown. The decoder's hardware/software status is logged once per codec start.

Source: external architecture review 2026-10-03 (H05, LM2, LM5, LM6, D5, PF7); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W1, additional issues 1, 4, 6), docs/reviews/2026-10-03/coverage-audit.md (§3 PF7 client part).

## Bağlam

**What the number is today** (verify-E, H05/LM2):
- Chain: `VideoRenderer.kt:548` `stats.onOutput(info.presentationTimeUs, nowUs())` → `VideoStats.kt:137-139` `latencyOf?.invoke(cap)` → `MainActivity.kt:1165` `clock.latencyUs(cap, SessionController.clockUs())` → `ClockSync.kt:29-32`.
- It is computed **before** pacing (`adaptivePacer.schedule`, `VideoRenderer.kt:559-561`), before `releaser.submit` (`:573`) and before `releaseOutputBuffer` (`CodecSink.release`, `:499-501`).
- `ClockSync.kt:31` clamps every sample to ≥ 0 (`.coerceAtLeast(0)`). The window value is a mean only (`VideoStats.kt:151,182`).
- Frames that are decoded and later discarded by the SlotReleaser (`CodecSink.discard`, `:503-505`) still add a latency sample.
- `rendered` counts `releaseOutputBuffer` calls (`:501,509`) but is logged as `shown=` in `MB/decoder ev=stats` (`MainActivity.kt:1459`) and drives the overlay "FPS" and the host fps.
- The overlay label is "Gecikme" (`StatsFormat.kt:30`).
- Already present and not to be duplicated: `dec_*` percentiles, `pace_add_ms`, net/ready/shown gap percentiles, `clock_offset_us`, `rtt_us` (`MainActivity.kt:1465-1477`), and the per-frame `pace_trace`.

**Stale per-frame maps (verify-E additional issue 1, inferred, JVM-testable):**
- `VideoStats.inputTimes` / `captureTimes` (`VideoStats.kt:64-65`) are keyed by codec pts = `frame_seq`, evict `keys.min()` above 64 entries (`:116-121`), and are removed only by a matching `onOutput`.
- `frame_seq` restarts at 0 on every video connection (PROTOCOL §0x41). `VideoStats` lives as long as the renderer. Frames lost in a codec teardown and codec-config inputs leave stale high keys behind.
- Once ~60 stale high keys build up, every new low key is the minimum and is evicted at once. `decode_avg_us` then reads 0 and latency reads "?" until `frame_seq` passes the stale keys. `AvSync.videoLatencyUs` (`MainActivity.kt:1393`) gets null for that time.
- The renderer's own `captureByPts`/`readyByPts` are already cleared per codec run (`VideoRenderer.kt:383`). `VideoStats`'s maps are not.

**PF7 client part (coverage audit §3):** `MediaCodec.createDecoderByType(mime)` (`VideoRenderer.kt:294`) takes the platform default. Only `name=` is logged (`ev=codec_start`, `:322-323`). minSdk is 29, so `MediaCodecInfo.isHardwareAccelerated` / `isSoftwareOnly` are always available. No warning exists if a software decoder (e.g. `c2.android.hevc.decoder`) is picked. Mirrors T-187 on the host. After T-158 the renderer reaches the codec only through `DecoderCodec`, whose interface holds only what the renderer already calls, so a read-only diagnostic accessor (e.g. `isHardwareAccelerated`/`isSoftwareOnly`, or the `codecInfo` flags) is added to `DecoderCodec.kt`, the MediaCodec adapter, and T-159's fault-injecting decorator `DecoderFault.kt` (unless it already delegates with `by`). Diagnostic accessor only; no other interface change.

**Plan hints:**
- `drainOutput` (`VideoRenderer.kt:527-573`) has `readyNs` and `d.slotNs`; ready→slot = `d.slotNs − readyNs`.
- `CodecSink.release(idx, renderNs)` (`:499`) does not know the pts. Pass a pts → captureUs lookup (`captureByPts` already exists) or tag through `SlotReleaser.Sink.release`.
- `cap_cb_*` comes from the `OnFrameRenderedListener` (`:389-397`). It exists only when `codecReportsShown` is true (codec-render mode); in other modes log `-`.
- The render callback runs on the main looper: keep the `VideoStats` methods `@Synchronized`.
- Signed internally: add a signed variant of `ClockSync.latencyUs`; clamp only where a u32 is written (`StatsFormat.kt:19`).
- Keep the A/V sync input and STATS `latency_avg_us` numerically as today (mean of clamped capture→decode), so audio behaviour does not change in this card.
- This card does **not** correct the ~6.6 ms SCK PTS lead. That is decision 0021 (T-172).
- Clock uncertainty: on USB about ±2.3 ms (RTT 4.6 ms); on loaded Wi-Fi up to about ±12–14 ms. The bias under Wi-Fi load is toward under-reporting (verify-E LM5).

**Order and hot files:**
- Serialize with the `VideoRenderer.kt` chain T-158 → T-159 → T-160 → T-161 → **T-168** → T-183 → T-184. T-161 is a dependency; T-183 must start after this card merges.
- Serialize with T-158 (same file `DecoderCodec.kt`) and T-159 (same file `DecoderFault.kt`). Both are upstream through T-161 (depends_on), so this only matters if either is reopened.
- Serialize with the `MainActivity.kt` chain … T-160 → **T-168** → T-169 → T-183 …
- `MainActivity.kt` may be touched only in `statsTick`, `writeStatsLog` and the `latencyOf` wiring.
- T-183 (retire experiments) compares stats against NOTES using the new names or their aliases, so keep the aliases for one release.

**Risk:** renaming log fields breaks old analysis scripts and NOTES comparisons. Keep `latency_us=` and `shown=` as aliases for one release and list them in LOGGING.md as deprecated.

## Kapsam dışı

- Wire changes: the STATS byte layout and the meaning of `latency_avg_us` on the wire are unchanged.
- Host side (T-170), the 6.6 ms lead and the capture-stamp decision (T-172), optical measurement (T-174).
- SurfaceControl present fence or FrameTimeline (API 33; the tablet is API 31).
- The `pace_trace` CSV columns and `tools/pacing/` field names.
- Refresh fields `hz=`/`display_hz=` (T-169).

## Kabul kriterleri

- [ ] [JVM] `MB/render ev=stats` gains: `cap_dec_p50/p95/p99/max_us` (with `latency_us=` kept as an alias for one release); `ready_slot_p50/p95/p99_us`; `cap_rel_p50/p95/p99/max_us`; `cap_cb_p50/p95/p99/max_us` (codec-render mode, else `-`); `render_cb_missing` (releases without a render callback in the window); `lat_neg` (count of negative raw samples); `clock_unc_us` (= best RTT / 2). Tested through `VideoStats`/`StatsFormat` tests.
- [ ] [JVM] The raw latency is signed. Negative samples go into `lat_neg` and the distributions. The clamp applies only where a u32 is written (STATS). STATS `latency_avg_us` and the A/V sync input keep today's values.
- [ ] [JVM] Only released frames count toward `cap_rel`/`cap_cb`. Discarded frames are excluded and counted separately (e.g. `discarded=`).
- [ ] [JVM] `VideoStats` per-frame maps are cleared on stream and codec boundaries (or keyed by codec generation). Test: 70 stale high keys, then a new stream starting at seq 0 still yields decode and latency samples from its first frames.
- [ ] [JVM] `MB/decoder ev=stats` `shown=` → `released=` (with `shown=` kept as an alias for one release).
- [ ] The overlay "Gecikme" becomes "Yak→çöz", and one overlay line shows `ready→slot p50` and `±clock`.
- [ ] `ev=codec_start` gains `is_hw=0|1 sw_only=0|1`. A software-only or non-hardware decoder logs one `W decoder ev=codec_software` warning per codec start.
- [ ] [doc] `docs/LOGGING.md` documents the new fields, the aliases, and that `cap_dec` excludes the SCK lead and pacing.
- [ ] [device] On USB at 120 Hz while drawing: the new fields appear; `ready_slot_p50` ≈ 13–17 ms (consistent with NOTES trace2/trace7); `lat_neg` = 0; `is_hw=1`.
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
