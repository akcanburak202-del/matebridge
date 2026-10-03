---
id: T-168
title: Break client latency into stages with percentiles; stop clamping; fix stats maps; log decoder hardware
status: review
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

1. `ClockSync`: `latencySignedUs(cap, clientUs)` (işaretli, saat `System.nanoTime` µs); `latencyUs` = onun ≥0 kırpılmışı (davranış aynı).
2. `IntervalHistogram`/`IntervalSummary`: kesin `maxUs` (pencere birleştirmede de korunur); negatif örnek kabul eder.
3. `VideoStats`:
   - `latencyOf` → `(captureHostUs, clientUs) -> Long?` işaretli. `onOutput(pts, nowUs, clientUs)`: ham değer `cap_dec` dağılımına, `<0` ise `lat_neg`; ortalama (STATS `latency_avg_us`, A/V girişi) bugünkü gibi kırpılmış örneklerin ortalaması.
   - Yeni: `onReadySlot(us)`, `onReleased(pts, captureUs, clientUs, expectCallback)` (rendered++ ve `cap_rel`), `onDiscarded()`, `onRenderCallback(pts, captureUs, clientUs)` (`cap_cb`; sıralı bekleyen kümesi → `render_cb_missing`).
   - Kare haritaları ekleme sırasına göre sınırlı (`keys.min()` yerine en eski çıkar) ve `resetFrames()` ile kod çözücü başlangıcında ve `closeWindow()`'da temizlenir.
   - Snapshot'a `capDec/readySlot/capRel/capCb`, `latNeg`, `discarded`, `renderCbMissing` (varsayılanlı, sona).
4. `VideoRenderer`: kod çözücü başında `stats.resetFrames()`; `onOutput`'a `readyNs`; karar varsa `slotNs−readyNs`; `CodecSink` idx→pts tutar, `release/releaseNow`'da `cap_rel`, `discard`'da `discarded`; render geri çağrısı (ana iş parçacığı, paylaşılan kilit yok) `cap_cb`. `codec_start`'a `is_hw= sw_only=`, yazılım çözücüde bir kez `W decoder ev=codec_software`.
5. `DecoderCodec`: salt okunur `isHardwareAccelerated`/`isSoftwareOnly` (varsayılan null), `MediaCodecDecoder` `codecInfo`'dan; `DecoderFault` açıkça devreder.
6. `StatsFormat`: `stageFields()` (boşsa `-`), `latencyStageFields()`; bindirmede "Gecikme" → "Yak→çöz", yeni satır `Hazır→slot p50 … | saat ±…`.
7. `MainActivity` (yalnız `latencyOf` bağlantısı, `statsTick`, `writeStatsLog`): `released=` (+`shown=` takma ad), render satırının sonuna yeni alanlar, `clock_unc_us`.
8. Testler (JVM): ClockSync işaretli, histogram max, 70 bayat yüksek anahtar + seq 0, atılanlar `cap_rel` dışında, `render_cb_missing`, alan biçimi, bindirme, `codec_software` uyarısı. LOGGING.md ayrı blok.

Riskler: paylaşılan kilit altında yalnız bellek içi iş (stats + ClockSync monitörü, ikisi de yaprak kilit); render geri çağrısı paylaşılan kilidi almaz.

## Handoff

- **Commit:** `58525b3` (kod + testler), `04cf4c8` (LOGGING.md ayrı blok), `2e40a05` (codex inceleme P2 düzeltmesi); plan `86915a0`. Dal `task/T-168-client-latency-stage-stats`. `./scripts/check.sh` ALL OK.
- **Dokunulan dosyalar:** `VideoStats.kt`, `VideoRenderer.kt`, `DecoderCodec.kt` (yalnız `isHardwareAccelerated`/`isSoftwareOnly`, varsayılan null), `DecoderFault.kt` (açık devretme), `IntervalHistogram.kt` (`IntervalSummary.maxUs`), `ClockSync.kt` (`latencySignedUs`, `uncertaintyUs`), `StatsFormat.kt`, `MainActivity.kt` (yalnız `latencyOf` bağlantısı, `statsTick`, `writeStatsLog`), testler: `video/LatencyStageStatsTest.kt` (yeni), `stream/LatencyStageFormatTest.kt` (yeni), `video/FakeDecoderCodec.kt` (hw bayrakları + `codecs` listesi), `stream/StreamTest.kt` ve `stream/StatsLogWindowTest.kt` (yeni `latencyOf` imzası, "Yak→çöz"), `docs/LOGGING.md`.
- **Varsayımlar:**
  - `lat_neg` yalnız `cap_dec` (yakalama→çözücü çıkışı) negatif örneklerini sayar; sonraki aşamalar bundan büyük olduğu için çift sayım yok.
  - `cap_dec` atılan kareleri de içerir (çözüm aşaması); `cap_rel`/`cap_cb` yalnız bırakılanları. `discarded=` ayrıca `drop=` içinde de sayılır (STATS `frames_dropped` değişmedi).
  - Codex P2 (düzeltildi, `2e40a05`): codec-render modunda kare `releaseOutputBuffer`'dan **önce** beklenenlere eklenir (`VideoStats.awaitCallback`), çünkü ana looper'daki geri çağrı, çağrı dönmeden gelebilir. Çağrı hata fırlatırsa kayıt geri alınır (`cancelCallback`, eksik sayılmaz). Codec çağrısı paylaşılan kilidin dışında kalır. Test: `LatencyStageRendererTest.callbacksDeliveredBeforeTheReleaseReturnsAreNotMissing` (sahte codec geri çağrıyı `releaseOutputBuffer` içinde verir) ve iki `VideoStats` birim testi.
  - `render_cb_missing`: geri çağrılar bırakma sırasıyla gelir varsayımı; daha sonra bırakılmış bir karenin geri çağrısı gelince öncekiler "eksik" sayılır; 64 bekleyen sınırı aşılınca en eski eksik sayılır. Codec durunca bekleyenler sayılmadan atılır.
  - Saat tabanı: `readyNs`, bırakma anı ve geri çağrı `nanoTime`'ı `System.nanoTime` (= `SessionController.clockUs()`); `onOutput`'un `nowUs` (elapsedRealtime) yalnız çözme süresi için.
  - Bayat harita düzeltmesi iki katmanlı: ekleme sırasıyla sınır (`keys.min()` yerine en eski) + her codec başında ve `closeWindow()`'da `resetFrames()`.
  - Paylaşılan kilit altında yalnız bellek içi iş eklendi (VideoStats ve ClockSync monitörleri yaprak kilit). Render geri çağrısı paylaşılan kilidi almaz; VideoStats monitörünü alır (kart ipucu: `@Synchronized` kalsın).
  - STATS `latency_avg_us` ve A/V girişi: kırpılmış örneklerin ortalaması, örnek anı artık `readyNs` (eskiden birkaç µs sonra `clockUs()`); sayısal fark ihmal edilebilir.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - USB, 120 Hz, çizim sırasında `adb logcat -s 'MB:*'`: `MB/render ev=stats` sonunda `cap_dec_* ready_slot_* cap_rel_* cap_cb_* render_cb_missing= discarded= lat_neg= clock_unc_us=` var; `ready_slot_p50_us` ≈ 13 000–17 000 (NOTES trace2/trace7 ile tutarlı); `lat_neg=0`; `clock_unc_us` ≈ 2 300; sıra `cap_dec ≤ cap_rel ≤ cap_cb` (p50).
  - `latency_us=` hâlâ yazılıyor ve eski değere yakın (~11 ms); `MB/decoder ev=stats` `released=` ve `shown=` aynı değer.
  - `I decoder ev=codec_start ... is_hw=1 sw_only=0 accepted ...`; `codec_software` uyarısı yok.
  - `render_cb_missing` HarmonyOS'ta ~0 mı (çok büyükse codec geri çağrıları seyrek; NOTES'a düşülmeli).
  - Bindirme: "Yak→çöz N ms" ve `Hazır→slot p50 N ms | saat ±N ms` satırı görünüyor, taşma/kesilme yok. GL yolunda `cap_cb_*`/`render_cb_missing` `-`.
  - A/V senkron davranışı değişmemeli (ses gecikmesi aynı).
- **Açık sorular:**
  - Mac menüsü "yak→çöz" etiketi T-170'te; bu kart host'a dokunmadı.
  - `IntervalSummary.maxUs` sona varsayılanlı eklendi; diğer çağıranlar etkilenmedi.
