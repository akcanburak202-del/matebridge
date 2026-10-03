---
id: T-185
title: Gate debug extras behind `dev`; add `ev=profile`; move NetBench to debug
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-184, T-146]
decisions: [0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/AudioPlayout.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/bench/
  - client-android/app/src/debug/kotlin/dev/matebridge/client/bench/
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/debug/AndroidManifest.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/bench/NetBenchTest.kt
  - backlog/tasks/T-185-client-dev-knob-gate.md
---

## Amaç

`MainActivity` is the exported launcher, and the daily APK is the debug variant. So any app on the tablet, or a mistyped `am start`, can switch experiment behaviour: a raw TCP bench to an arbitrary host, QuickACK off, a forced transport, audio off. Nothing in the logs says which knobs were active. After this card:
- debug-only extras work only when `--ez dev true` is passed on the same launch;
- ignored keys are logged;
- every session logs one `ev=profile` line with the effective mode, the build SHA and the non-default knobs, so every measurement names its configuration;
- the NetBench tool moves out of the main source set.

Source: external architecture review 2026-10-03 (L02, D8); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-C3, additional issue 3) and docs/reviews/2026-10-03/verify-A-security.md (A7).
Decision 0026 must be accepted by the user before work starts.

## Bağlam

**Evidence at HEAD (a30c769).** Paths are relative to `client-android/app/src/main/kotlin/dev/matebridge/client/`.
- Exposure:
  - `MainActivity` is `exported="true"` (`client-android/app/src/main/AndroidManifest.xml:19-28`), and it reads its extras in `onCreate` and helpers (`MainActivity.kt:294-496`);
  - `audio/AudioPlayout.kt:94` (`audio_buf_bursts`) and `:114` (`audio_out`) read the Activity intent directly, so they must be gated too;
  - the daily APK is the debug build (`scripts/install-apk.sh:15`; no `buildTypes`).
- `net_bench` (`MainActivity.kt:356-365`) forwards to `bench/NetBenchActivity`, which connects to an arbitrary `host:port`. The bench code is `bench/NetBench.kt`, `NetBenchActivity.kt` and `NetBenchRunner.kt` (322 lines). Its manifest entry is at `AndroidManifest.xml:29-34`.
- The debug `VideoTestActivity` is `exported="true"` (`client-android/app/src/debug/AndroidManifest.xml:5-6`).

**Class per key** (from decision 0026 / `docs/KNOBS.md`, T-182). After T-183/T-184, the remaining extras are:
- **debug-only (gated):** `jitter`, `hz`, `lead_us`, `deadline_us`, `ping_ms`, `tos_ctl`, `tos_video`, `wifi_ll`, `audio`, `transport`, `audio_out`, `audio_buf_bursts`, `quickack`, `net_bench` (+ sub-keys).
- **keep (not gated):** `stats_1s`, `pace_trace`, `stall_diag`.
- If 0026 classifies a key differently, follow 0026 and say so in Handoff.

**Design hints:**
- `DevKnobs.parse(has, …)` is pure. It returns the effective values plus the list of ignored debug-only keys. Without `dev` every debug-only key keeps its default.
- Log once at start: `diag ev=dev_knobs dev=0|1 ignored=<keys>|-`. Keys only, never values that could be personal (the `net_bench` host is not logged when ignored).
- **`ev=profile`** is logged once at `installConfig` (`MainActivity.kt:1147`) per config. Fields:
  - effective stream mode, fps, scale, bitrate setting, transport, audio output;
  - pacer (adaptive / buffer N);
  - `sha=` and `built=` from T-146 `BuildInfo`;
  - `dev=0|1` and `knobs=<non-default keys>|-`.
  - no `is_hw=`: at `installConfig` the codec restarts asynchronously (`r.reconfigure(config)`, `MainActivity.kt:1176`), so this config's decoder is not known yet. `is_hw` is in `ev=codec_start` since T-168.
  No serial number, no device ID, no endpoint address.
- **Moving the bench:** main code cannot reference debug-source-set classes. Keep the `"net_bench"` key string in main, gate it on `dev`, and start the bench activity by class name (`Intent().setClassName(packageName, "dev.matebridge.client.bench.NetBenchActivity")`), or use a tiny main/debug pair of objects. Move the `NetBenchActivity` manifest entry to `src/debug/AndroidManifest.xml`.
- `NetBenchTest` stays under `src/test`. `testDebugUnitTest` compiles against the debug source set; note in Handoff that a release unit-test run would not see the bench.
- **`VideoTestActivity` `exported="false"`, if feasible.** Risk: `adb shell am start -n …/.debug.VideoTestActivity` is refused for non-exported activities on a non-rooted device, which would break the decoder test harness. If so, keep it exported and write the reason in Handoff.
- The T-127 matrix rows use `--ei tos_ctl 0xB8 --ez wifi_ll true`. After this card those need `--ez dev true` as well. T-127 already says so (it adds `--ez dev true` when T-185 is in the build and checks `ev=dev_knobs ignored=-`), so keep the `dev_knobs` line format stable.
- `docs/LOGGING.md` needs the `ev=profile` and `ev=dev_knobs` lines. LOGGING is not in `files:`; write the text under *Açık sorular* for the orchestrator (T-142 precedent).

**Serialization:** `MainActivity.kt` chain … T-184 → T-185 → T-191 → T-197. `session/WifiKnobs.kt` is not edited here (T-197 owns the next change; audit K4).

Wire: none.

## Kapsam dışı

- Removing knobs (T-183, T-184); changing any default.
- Host side (T-186 `nw` sockets; T-204 host encoder knobs and host `ev=profile`); settings reset (T-191).
- Making `MainActivity` non-exported (it is the launcher).

## Kabul kriterleri

- [ ] [JVM] `DevKnobsTest`: without `dev` every debug-only key keeps its default and is listed in `ignored`; with `dev=true` all are applied; keep-class keys (`stats_1s`, `pace_trace`, `stall_diag`) apply either way; absent extras give an empty ignore list.
- [ ] [JVM] The `ev=profile` field builder produces the documented fields and never contains an endpoint address, serial number or device ID.
- [ ] [JVM] `NetBenchTest` still passes after the move to `src/debug`.
- [ ] [device] `am start … --ei jitter 1` without `dev` logs `ev=dev_knobs dev=0 ignored=jitter` and the pacer stays adaptive. With `--ez dev true` the buffer-1 pacer is used.
- [ ] [device] `--es net_bench <host:port>` without `dev` does not start the bench; with `dev` it does.
- [ ] [device] Every session start logs exactly one `ev=profile` line whose `sha=` matches the T-146 `ev=app_start` line. A mode change logs a new one.
- [ ] [doc] Handoff says whether `VideoTestActivity` is now `exported="false"` and, if not, why.
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
