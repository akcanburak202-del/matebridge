# Pürüzsüzlük ve gecikme araştırması (2026-10-04)

Kaynak: orkestratörün başlattığı araştırma ajanı (web + repo okuması, kod değişikliği yok). Rapor İngilizce; kararlar ve kartlar Türkçe tutulur. Web kaynaklarının bir kısmı blog/üretici iddiasıdır, kullanıldığı yerde belirtilmiştir.

## Türkçe özet

- MateBridge'in zamanlayıcısı açık kaynak istemcilerin hepsinden ileride (yakalama damgasından zamanlama, faz kilidi, 2:1 kilit). Hiçbiri host'un üretmediği kareyi onaramaz.
- **Yeni ve ucuz:** HiSilicon decoder için Moonlight'ın kullandığı `vendor.hisi-ext-low-latency-video-dec.*` anahtarları, `vdec-lowlatency`, ve `KEY_OPERATING_RATE = Short.MAX_VALUE`. Oyun 60'ta 2800×1840 çözme p50 ~18 ms, 120 fps çizimde aynı boyut ~9,3 ms → büyük olasılıkla DVFS (60 fps'te düşük saat). A/B kartı: T-217.
- **Takılma sonrası sekme hipotezi:** 50–100 ms'lik kaynak boşluğundan sonra ilk kare "yalnız kare" sayılıp kilitsiz gidebilir. Önce eldeki izle doğrulanır.
- **Mac tarafındaki eksik kareler** (50–100 ms) büyük olasılıkla oyun/çeviri katmanı (GameHub = Wine/GPTK) kaynaklı; Metal HUD (`MTL_HUD_ENABLED=1 MTL_HUD_LOGGING_ENABLED=1`) ile doğrulanır. macOS Oyun Modu yalnız tam ekranda ve sanal ekranda çalışıp çalışmadığı bilinmiyor.
- **Önerilmeyen:** kare enterpolasyonu (gecikme ≥ doldurulan boşluk), kaynakta kare tekrarı, büyük tampon, API 33 frame timeline (cihaz API 31), slice/SurfaceControl/H.264/ADPF (ölçülüp kapandı).
- 0029'un USB faydası, oyun modunun "Otomatik"te 60 Mbps zorlaması yüzünden azalır; bit hızı kuralı T-216 ölçümünde karara bağlanmalı.
- Huawei PerfGenius (`libPerfgeniusApi.so`, `SetFrameRate`) dokunmasız 120 Hz için keşfedilmemiş bir yol; HMS/AppGallery gerektirebilir, karar kaydı ister.

## 1. Other systems: pacing, jitter, drops, clock drift

- **Moonlight (Android):** modes MIN_LATENCY / BALANCED / CAP_FPS / MAX_SMOOTHNESS. MIN_LATENCY releases immediately (`releaseOutputBuffer(idx, System.nanoTime())`); BALANCED keeps ≤2 outputs, Choreographer `doFrame` releases the newest with `frameTimeNanos`, skips a release if < 80% of a period elapsed. No clock-drift model. ([MediaCodecDecoderRenderer.java](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/master/app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java), [#1096](https://github.com/moonlight-stream/moonlight-android/issues/1096))
- **Moonlight decoder keys (HiSilicon path):** for `omx.hisi*`/`c2.hisi*` it sets `vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req=1` and `…-rdy=-1`; also `vdec-lowlatency=1`, `low-latency=1`, `KEY_PRIORITY=0`; `KEY_OPERATING_RATE=Short.MAX_VALUE` only for an allowlist. ([MediaCodecHelper.java](https://raw.githubusercontent.com/moonlight-stream/moonlight-android/master/app/src/main/java/com/limelight/binding/video/MediaCodecHelper.java)) MateBridge sets none of these (`VideoRenderer.kt` ~:342-359, `OperatingRate.kt`). No public benchmark; weak evidence ([#1120](https://github.com/moonlight-stream/moonlight-android/issues/1120)).
- **Sunshine:** duplicates frames down to `minimum_fps_target` to keep clients fed, not for smoothness ([config](https://docs.lizardbyte.dev/projects/sunshine/latest/md_docs_2configuration.html)).
- **Parsec:** client vsync on by default, drops accumulated frames when server rate exceeds client refresh ([blog](https://parsec.app/blog/description-of-parsec-technology-b2738dcc3842)).
- **scrcpy:** shows each frame on decode; optional `--video-buffer`; encoder `KEY_REPEAT_PREVIOUS_FRAME_AFTER` 100 ms ([video.md](https://github.com/Genymobile/scrcpy/blob/master/doc/video.md)).
- **WebRTC:** `playout-delay` min=max=0 for gaming; default jitter buffer ~125 ms ([doc](https://webrtc.googlesource.com/src/+/main/docs/native-code/rtp-hdrext/playout-delay/README.md)).
- **AirPlay (unofficial):** NTP/PTP-like sync, ~90 ms video latency ([openairplay](https://openairplay.github.io/airplay-spec/screen_mirroring/time_synchronization.html)).
- **Sidecar/Duet/Spacedesk:** no credible public pacing write-up; Astropad's numbers (Luna USB 11.3 ms, Duet 95 ms) are a vendor claim ([astropad](https://astropad.com/latency-comparison/)).
- Clock drift: MateBridge measured 14 ppm (T-083) → one slip per ~20 min at 60 Hz; negligible.

## 2. Android APIs (tablet API 31)

- `releaseOutputBuffer(idx, ts)`: shown at the vsync at/after `ts` (within 1 s); several to one vsync → last wins ([MediaCodec](https://developer.android.com/reference/android/media/MediaCodec)). MateBridge's 6 ms deadline (T-061/T-071) is empirically tuned.
- `Surface.setFrameRate` (`CHANGE_FRAME_RATE_ALWAYS`) is a hint; vendor policy wins ([guide](https://developer.android.com/media/optimize/performance/frame-rate)) — matches T-140 (Huawei AGP).
- Frame timelines need API 33 — unavailable. `setDesiredPresentTime` judged 0–1.5 ms (T-084). ADPF absent on HarmonyOS 4.3 (T-079).
- `OMX.hisi.video.decoder.hevc` advertises no low-latency/tunneled features (NOTES 10-02); vendor keys are the remaining lever. API 31 `MediaCodec.getSupportedVendorParameters()` lists exposed `vendor.*` keys.
- Huawei: PerfGenius (`dlopen("libPerfgeniusApi.so")`, `SetFrameRate`, `GetSupportedFrameRate`, `AddKeyThreads`, `SetScene`; AppGallery Connect setup) ([codelab](https://developer.huawei.com/consumer/en/codelab/HMSAccKit-PerfGenius/)) — untested here; GameTurbo Engine (`com.huawei.game:gamekit`) is an HMS dependency ([API](https://developer.huawei.com/consumer/en/doc/development/HMSCore-References/gamekitpac-api-0000001050121690)). Community: MatePads stay 60 Hz without input ([XDA](https://xdaforums.com/t/need-to-figure-out-how-to-force-120hz-for-matepad-11-5-or-any-120hz-huawei-devices.4616341/)).

## 3. macOS capture and missing frames

- SCK rules (WWDC22 10155): process each frame within `minimumFrameInterval`; release surfaces within `minimumFrameInterval × (queueDepth−1)`. MateBridge complies (queueDepth 5, `sck_lag=0`).
- macOS 27 SDK adds no cadence/latency knob to SCK.
- On a fixed-rate display a missed vsync repeats the previous frame (WWDC21 10147) → SCK emits nothing. 2026-10-04 data (pts 99.52% at 16.7 ms, `status=complete`, ~0.55 missing frames/s, 47 gaps of 50–100 ms) points to game-side hitches (shader compile, streaming, translation layer). GameHub = Wine/GPTK layer ([Geeky Gadgets](https://www.geeky-gadgets.com/play-pc-games-on-mac-gamehub/)) — inference.
- Diagnose: `MTL_HUD_ENABLED=1 MTL_HUD_LOGGING_ENABLED=1` (logs present intervals/GPU time; overlay visible on tablet) ([tech talk](https://developer.apple.com/videos/play/tech-talks/110339)). macOS Game Mode only in native full screen ([Apple](https://support.apple.com/en-us/105118)); unknown on CGVirtualDisplay.
- `VTLowLatencyFrameInterpolation` (macOS 26+) needs current + previous frame; filling a 50–100 ms gap would delay every frame by at least that — not worth it.

## 4. Encoder and transport

- VT low-latency RC (WWDC21 10158): measured slower here (~9–13 ms vs ~6 ms "fast", T-047/T-053) — keep "fast".
- macOS 26 VBV keys (`VBVMaxBitRate`, `VBVBufferDuration`, …) might bound P-frame spikes; incompatible with LLRC/`DataRateLimits`; untested.
- No public intra-refresh key in VT. Slices: no partial-frame output on either side — closed.
- USB 2.0 (~35 MB/s): 125 KB ≈ 3.6 ms, keyframe 432 KB ≈ 12 ms; game camera cuts 300–400 KB ≈ 9–11 ms.
- HEVC decodes faster than AVC on HiSilicon (1080p 258 vs 149 fps); keep HEVC.
- 0029: encode ~∝ pixels; decode not linear (T-144: 100%→85% gave 9.3→8.0 ms, ~3.7 ms fixed cost). USB saving only if bitrate scales (game mode forces 60 Mbps on Auto).
- **Decode anomaly:** 2800×1840 decode p50 ~9.3 ms at 120 fps (T-144) vs ~18–19 ms at 60 fps game mode (2026-10-04); bytes/frame barely matter (T-085). 2100×1380@60 decoded 8.7 ms → DVFS more likely than an OMX hold. Lever: operating rate high + vendor low-latency keys (today operating rate = stream fps).

## 5. Perception

- Stylus: drag latency perceivable to 2–6 ms, scribble ~40 ms, writing ~53 ms ([CHI 2014](https://webdocs.cs.ualberta.ca/~wfb/publications/C-2014-SIGCHI-Latency.pdf)). MateBridge drawing ~38–40 ms → latency matters more than ~1% double frames (T-080 verdict).
- Games: tolerance ~100 ms (first person) to 1000 ms ([Claypool 2006](https://cacm.acm.org/magazines/2006/11/5798-latency-and-player-actions-in-online-games/fulltext)); frame-time variation strongly predicts QoE ([CHI'23](https://web.cs.wpi.edu/~claypool/papers/frame-variation-chi-23/paper.pdf)). +5 ms for steady cadence (T-210/T-211) is the right trade; 50–100 ms source hitches cannot be buffered away.

## Ranked recommendations

1. **Decoder latency knobs A/B** (vendor hisi keys, `vdec-lowlatency`, operating rate max, log vendor params) behind a dev knob with configure fallback → T-217. Measure `dec_p50/p95`, `latency_us`, SoC temp; Oyun 60 full res and 120 fps drawing.
2. **Hitch-aware lock:** verify with the 2026-10-04 trace whether frames after a 50–100 ms gap lose the lock; if so keep the lattice across hitches after a continuous locked run.
3. **Diagnose game-side misses** (Metal HUD, native game vs GameHub, native full screen + Game Mode, in-game 60 cap + vsync).
4. **Ship 0029 and measure**; decide the game-mode bitrate rule (scale bitrate with resolution).
5. **Probe PerfGenius `SetFrameRate(120)`** (exploratory; may need decision/HMS).
6. `Window.setPreferMinimalPostProcessing(true)` in game modes (cheap probe, likely no-op).
7. 120 Hz virtual display with in-game 60 cap (low priority).
8. VBV keys encoder bench (low priority).

Not recommended: interpolation, source-side repetition, bigger buffers, API 33 timelines, revisiting slices/SurfaceControl/H.264/ADPF.
