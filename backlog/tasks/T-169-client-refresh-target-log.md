---
id: T-169
title: Log target and real refresh separately; warn on a mismatch
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-168]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/RefreshMismatch.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - docs/LOGGING.md
  - backlog/tasks/T-169-client-refresh-target-log.md
---

## Amaç

The per-window stats line logs the same refresh value twice (`hz=` and `display_hz=`) and never states which panel rate the client asked for. On this tablet the panel rate also depends on the input type (pen and trackpad force 120 Hz, keyboard falls back to 60 Hz), so a run's real Hz can silently differ from its target. After this card every log window shows the requested vs the actual panel Hz, and a sustained mismatch is logged once. This makes every latency and fps measurement (T-127, T-174) interpretable.

Source: external architecture review 2026-10-03 (X12); verification: docs/reviews/2026-10-03/verify-E-measurement.md (W7, additional issue 5, PF3).

## Bağlam

**Evidence:**
- `hz=` and `display_hz=` are both `currentHz()` = `windowManager.defaultDisplay.refreshRate` (`MainActivity.kt:1295`, `:1467-1468`).
- The real cadence is measured separately: `vsync_ms_p50` (Choreographer gaps, `:1468`) and `vsync_period_us`.
- The target is logged only when it changes: `display_mode requested_hz=… current_hz=` (`applyRefreshRate`, `:1299-1310`) and `display_rate hz=` (`:1230`).
- The target is `FrameRatePolicy.modeTargetHz(targetHz, streamConfig?.fps ?: 0)` (`FrameRatePolicy.kt:9`, used at `MainActivity.kt:1300`). The stream mode is `streamMode` (`MainActivity.kt:131`).
- Even the reported refresh rate is a proxy. NOTES records `sfFps 120` while AGP's `final lcd fps` was 60 (verify-E X12). `vsync_ms_p50` is the best available client-side signal.
- PF3: on this device, touch, pen, mouse and trackpad raise the panel to 120 Hz; keyboard and gamepad do not. A "60 Hz" measurement therefore needs keyboard-driven content.

**Plan hints:**
- Put the mismatch logic in a small pure class (`stream/RefreshMismatch.kt`, new) so it is JVM-testable. It takes (target Hz, measured Hz from `vsync_ms_p50`, streaming flag, now) and returns at most one event per episode. Rate limit: one line per episode, plus at most one per 60 s.
- Compare against the measured cadence (`vsync_ms_p50`), not `Display.refreshRate`. Use a tolerance (e.g. ±10 %). A target of 0 ("leave the mode alone") never mismatches.
- `MainActivity.kt` may be touched only in `statsTick` (the per-second `RefreshMismatch` feed; the per-second `vsync` p50 is computed there, `MainActivity.kt:1390`), the stats log line, and the `applyRefreshRate` logging. The stats log line is per 10 s window (T-141), too coarse to judge a > 5 s mismatch.

**Order and hot files:** serialize with the `MainActivity.kt` chain … T-168 → **T-169** → T-183 … T-168 is a dependency. T-183 must start after this card merges.

## Kapsam dışı

- Changing which refresh rate is requested, or any automatic mode switching (decision 0016 forbids it).
- Overlay changes; the STATS wire layout.
- AGP/LCD-level measurement (only via `tools/measure/`, T-173).

## Kabul kriterleri

- [ ] [JVM] The `MB/render ev=stats` line carries `target_hz=` (`FrameRatePolicy.modeTargetHz`), `display_hz=` (`Display.refreshRate`), `vsync_ms_p50=` (measured) and `stream_mode=`. `hz=` stays only as a duplicate alias for one release. The field formatting is covered by a test.
- [ ] [JVM] `RefreshMismatch` test: target ≠ measured Hz for more than 5 s while streaming → exactly one `ev=refresh_mismatch target_hz= measured_hz= dur_ms=` event. Shorter mismatches, target 0, and non-streaming time → none. A second episode after recovery → one more event, within the rate limit.
- [ ] [doc] `docs/LOGGING.md` documents `target_hz`, `stream_mode`, `ev=refresh_mismatch` and the `hz=` alias.
- [ ] [device] USB, Akıcı: drawing with the pen shows `target_hz=120` and `vsync_ms_p50≈8.3` with no mismatch. Typing only on the keyboard for >5 s shows one `ev=refresh_mismatch target_hz=120 measured_hz≈60` line.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `stream/RefreshMismatch.kt` (yeni, saf Kotlin):
   - `RefreshMismatch.statsFields(targetHz, displayHz, vsyncPeriodUs, vsyncP50Us, streamMode)` → `hz=<alias> target_hz= vsync_period_us= display_hz= vsync_ms_p50= stream_mode=` (eski `hz=` en başta kalır, naif `hz=` regex'leri `target_hz=`'e takılmasın).
   - `RefreshMismatch.update(targetHz, vsyncP50Us, streaming, nowMs): Event?`: ölçülen Hz = 1e6 / p50; ±%10 tolerans; hedef 0, akış yok → bölüm biter. Ölçüm yok (vsync döngüsü uyuyor, `count == 0`) bölümü bitirmez, ama 2 sn'den uzun boşluk bölümü yeniden başlatır. Hedef değişince bölüm yeniden başlar. Bölüm > 5 sn sürünce tek olay; olaylar arası en az 60 sn (bekleyen bölüm sınır dolunca, hâlâ sürüyorsa yazılır).
   - `Event.fields()` → `target_hz= measured_hz= dur_ms=`.
2. `MainActivity.kt`: `statsTick` içinde saniyelik vsync özetiyle `refreshMismatch.update(...)` → `MbLog.w("refresh_mismatch", …, "render")`; `writeStatsLog` içinde `hz=…display_hz=…vsync_ms_p50=` parçası `RefreshMismatch.statsFields(...)` ile değişir. `applyRefreshRate` dokunulmaz. Yerel birkaç satır (T-183 paralel çalışıyor; `rvote`'a bağımlılık yok).
3. Test: `stream/RefreshMismatchTest.kt` (alan biçimi, 5 sn eşiği, kısa uyumsuzluk, hedef 0, akış dışı, ikinci bölüm, hız sınırı).
4. `docs/LOGGING.md`: ayrı bölüm (T-169).
- Risk: `vsync_ms_p50` Choreographer aralığıdır, panel Hz'i değil (AGP `final lcd fps` farklı olabilir); kartta belirtildiği gibi en iyi istemci sinyali bu.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
