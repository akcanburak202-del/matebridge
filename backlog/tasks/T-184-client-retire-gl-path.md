---
id: T-184
title: Retire the GL presentation path
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-183]
decisions: [0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/GlPresenter.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/PresentStats.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/main/res/layout/activity_main.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/GameModeTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/PresentStatsTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/VsyncIdleTest.kt
  - backlog/tasks/T-184-client-retire-gl-path.md
---

## Amaç

The client has two video presentation paths: the daily SurfaceView path, and an experimental GL path (`--es render gl`). The GL path gave nothing: HarmonyOS holds the GL surface at 60 Hz too, its jitter buffer looked worse to the user and had a cold-start no-frame bug (T-019, parked), and the SurfaceView path reaches 120 Hz. Yet it doubles the Surface lifecycle code that the video-health and decoder-teardown work (T-159, T-161) must keep correct. Removing it leaves one Surface lifecycle.

Source: external architecture review 2026-10-03 (L02; H02/M03 surface paths); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-C2, L02 inventory row 4).
Decision 0026 must be accepted by the user before work starts, including the user's explicit confirmation of the GL retirement (T-182).

## Bağlam

**Evidence at HEAD (a30c769).** Paths are relative to `client-android/app/src/main/kotlin/dev/matebridge/client/`.
- `video/GlPresenter.kt` has 366 lines. `MainActivity.kt` has about 50 GL references, including:
  - import `:74`; fields `:172` (`videoGl`), `:218` (`glMode`), `:224` (`presenter`), `:221-222` (`presentStats`, `glVsync`);
  - extras `:367-369` (`render`, `frate`, `glpts`); jitter choice `:375`, `:381`;
  - view setup `:433-437`; both views wired `:440-441`, `:586`;
  - presenter start `:1095-1098`; `gl_fallback` `:1119-1130`; `:1139`;
  - `codecReportsShown = !glMode` `:1157`; surface choice `:1180`;
  - `glVsync.setDisplayTiming` `:1280`; `gl_stats` `:1394-1411`.
- `glVsync` also takes the `lead_us`/`deadline_us` overrides (`:388`, `:395`). Keep those extras working on the surface path's own `VsyncClock`, and remove only the `glVsync` copy.
- `video/PresentStats.kt` is used only by `GlPresenter` and the `gl_stats` line, so it goes too, with `PresentStatsTest`. `PresentMeter`/`VideoStats` are on the daily path and stay.
- `stream/GameMode.kt:112` has `GameJitter.Source.GL`; `GameModeTest.kt:186` tests it.
- `res/layout/activity_main.xml:15` declares `video_gl`.
- `VsyncIdleTest.kt:268` has a GL-model test case. `VsyncIdle` itself is generic and stays; only the GL-specific case goes, and only if it relies on `GlPresenter`.
- `codecReportsShown = !glMode` becomes `true`.
- `docs/LOGGING.md:78` mentions `render ev=gl_stats`. LOGGING is not in `files:`; write it under *Açık sorular* for the orchestrator.

**Interaction with other cards:**
- T-161/T-164 GL↔surface churn checks apply only while this path exists. If this card lands first, T-164 skips them (its acceptance already says so).
- T-019 is closed as won't-do by T-182.

**Serialization:** `MainActivity.kt` chain … T-183 → T-184 → T-185. `VideoRenderer.kt` chain ends with T-183 → T-184 (this card should not need `VideoRenderer.kt`; if it does, stop and note it under *Açık sorular*).

Wire: none.

## Kapsam dışı

- Any change to the SurfaceView path's behaviour, pacing or defaults.
- `lead_us`/`deadline_us` semantics (they stay debug-only extras on the surface path).
- `VsyncIdle` beyond removing a GL-only test case.

## Kabul kriterleri

- [ ] [JVM] All JVM tests pass. `GameModeTest` no longer references `Source.GL`; `PresentStatsTest` is removed together with `PresentStats.kt`.
- [ ] [JVM] No main or test source references `GlPresenter`, `glMode`, `videoGl`, `video_gl`, `PresentStats`, `gl_fallback` or `gl_stats` (grep in Handoff).
- [ ] [device] 20× background/foreground and 10× mode switches (Netlik 60 ↔ Akıcı 120 ↔ Oyun 60): no black screen, no `gl_*` lines, no `detach_slow`. Launching with `--es render gl` behaves like a normal launch.
- [ ] [device] `--ei lead_us` and `--ei deadline_us` still change the surface path's `ev=display_timing` values.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `video/GlPresenter.kt`, `video/PresentStats.kt`, `PresentStatsTest.kt` silinir.
2. `MainActivity.kt`: `glMode`, `videoGl`, `videoView` (artık hep `video`), `presenter`, `presentStats`, `glVsync`, `glDecoderSurface`, `glGeneration`, `glPresentationTime`, `frameRateOverride` kaldırılır; `render`/`frate`/`glpts` extra'ları ve `render_mode` satırı okunmaz/yazılmaz (karar 0026: `frate` de GL yolu düğmesi). `setSurfaceFrameRate` `FrameRatePolicy.surfaceRate(-1, fps)` ile bugünkü varsayılanı (akış fps'i) korur. `surfaceCreated/Destroyed` yalnız `video` yolunu tutar; `fallBackToSurface`/`gl_fallback`, `gl_stats` ve katmandaki GL satırları gider; `codecReportsShown = true`. `lead_us`/`deadline_us` yalnız `vsync` (`VsyncClock`) üzerinde kalır.
3. `stream/GameMode.kt`: `GameJitter.Source.GL` ve belgesi kaldırılır; `GameModeTest`'teki GL satırı silinir.
4. `activity_main.xml`: `video_gl` silinir.
5. `VsyncIdleTest`: GlPresenter modelini sınayan `glFirstFrameAfterSleepIsDrawnOnArrival` silinir (yüzey yolunun `FirstOutputBypass` testleri kalır).
6. `files:` dışındaki eski yorumlar (VideoRenderer, StatsFormat, VsyncIdle, LatencyStageStatsTest) ve LOGGING/KNOBS metni *Açık sorular*a yazılır.

Riskler: yüzey yaşam döngüsü (VideoHealth/VideoDeliveryGate/CodecGeneration) aynı kalmalı; yalnızca GL dalları silinir, yüzey dalının sırası değişmez.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
