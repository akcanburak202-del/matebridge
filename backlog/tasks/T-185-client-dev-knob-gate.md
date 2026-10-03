---
id: T-185
title: Gate debug extras behind `dev`; add `ev=profile`; move NetBench to debug
status: done
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

- [ ] [manifest] Other apps can no longer launch `VideoTestActivity` (`client-android/app/src/debug/AndroidManifest.xml`; T-182 finding, `docs/KNOBS.md` *Açık noktalar* 2: the daily APK is the debug variant, so today any app can start it with `fps`/`full_range`/`primaries`). If it is still launched over adb, keep it exported but guard it with a permission only the shell holds (e.g. `android:permission="android.permission.DUMP"`) and confirm `adb shell am start -n …/.VideoTestActivity` still works; otherwise set `exported="false"`. Note: a non-exported activity cannot be started from `adb shell am start` either. Added by the orchestrator 2026-10-03.
- [x] [JVM] `DevKnobsTest`: without `dev` every debug-only key keeps its default and is listed in `ignored`; with `dev=true` all are applied; keep-class keys (`stats_1s`, `pace_trace`, `stall_diag`) apply either way; absent extras give an empty ignore list.
- [x] [JVM] The `ev=profile` field builder produces the documented fields and never contains an endpoint address, serial number or device ID.
- [x] [JVM] `NetBenchTest` still passes after the move to `src/debug`.
- [ ] [device] `am start … --ei jitter 1` without `dev` logs `ev=dev_knobs dev=0 ignored=jitter` and the pacer stays adaptive. With `--ez dev true` the buffer-1 pacer is used.
- [ ] [device] `--es net_bench <host:port>` without `dev` does not start the bench; with `dev` it does.
- [ ] [device] Every session start logs exactly one `ev=profile` line whose `sha=` matches the T-146 `ev=app_start` line. A mode change logs a new one.
- [x] [doc] Handoff says whether `VideoTestActivity` is now `exported="false"` and, if not, why.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. `session/DevKnobs.kt` (pure): `LaunchExtras` interface (has/int/bool/string) and `DevKnobs.parse(extras)`.
   - `dev` = `--ez dev true`. A gated view hides every debug-only key unless `dev`; all effective values are read through it,
     so without `dev` they keep their defaults. `ignored` = debug-only keys present without `dev` (canonical order, keys only).
   - Debug-only: `jitter hz lead_us deadline_us ping_ms tos_ctl tos_video wifi_ll audio transport audio_out audio_buf_bursts
     quickack net_bench` (+ `net_bench_*` sub-keys) and also `decoder_fault`/`decoder_fault_after_s` (T-159, added after the
     0026 inventory; same exposure). Keep: `stats_1s pace_trace stall_diag`. `WifiKnobs.parse` is called with the gated view.
   - `StreamProfile.fields(...)` (pure) builds the `ev=profile` fields from enumerated values only; string knob values are
     canonicalised to known ids or `other`, so no endpoint/serial/device id can appear.
2. `MainActivity`: parse once in `onCreate`, log `diag ev=dev_knobs dev=0|1 ignored=<keys>|-`, replace every direct
   extra read with `DevKnobs` fields, start the bench by class name only when `dev`; log `ev=profile` in `installConfig`.
3. `AudioPlayout`: take `audio_out`/`audio_buf_bursts` from constructor parameters (gated by the caller) instead of the
   Activity intent.
4. Move `bench/*.kt` to `src/debug/kotlin/.../bench/`; move the `NetBenchActivity` manifest entry to the debug manifest.
5. Debug manifest: `VideoTestActivity` stays exported (adb `am start` must keep working) but gets
   `android:permission="android.permission.DUMP"`, which the shell holds and third-party apps cannot obtain.
6. Tests: `DevKnobsTest` (gate, ignore list, keep keys, profile fields/privacy); `NetBenchTest` unchanged under `src/test`.
7. Risks: the gate changes T-127/T-159/T-161 launch commands (they need `--ez dev true`); LOGGING/KNOBS text goes to
   *Açık sorular*.

## Handoff

- **Commit:** `cd93efb` (implementation; plan `06183f8`; this handoff is the next commit on `task/T-185-client-dev-knob-gate`). `./scripts/check.sh` ALL OK (host, probes, client, protocol). `DevKnobsTest` 15/15, `NetBenchTest` 10/10 (now compiled against `src/debug`). `:app:compileReleaseKotlin` also passes, so main no longer references the bench classes.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt` (new): `LaunchExtras`, `DevKnobs.parse` (gated view; `ignored`, `knobs`, effective values), `StreamProfile.logFields`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`: `parseDevKnobs()` + `diag ev=dev_knobs` once in `onCreate`. Every launch-extra read now comes from `devKnobs`; no `intent.get*Extra` is left except the USB/battery broadcasts. The bench is started by class name only with `dev` (`ActivityNotFoundException` → `W diag ev=net_bench err=not_in_build`, and the session continues). `logProfile()` runs in `installConfig`.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/audio/AudioPlayout.kt`: `audio_out`/`audio_buf_bursts` arrive as constructor parameters (`launchOutRaw`, `launchBufBursts`) instead of being read from the Activity intent.
  - `client-android/app/src/main/kotlin/dev/matebridge/client/bench/*` → `client-android/app/src/debug/kotlin/dev/matebridge/client/bench/` (`git mv`, only a doc comment changed).
  - `client-android/app/src/main/AndroidManifest.xml` (NetBench entry removed), `client-android/app/src/debug/AndroidManifest.xml` (NetBench entry added; `VideoTestActivity` guarded by `DUMP`).
  - `client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt` (new). `NetBenchTest.kt` unchanged.
- **VideoTestActivity:** it is NOT `exported="false"`. Reason: a non-exported activity cannot be started by `adb shell am start` (the shell uid is not the app uid), which would break the T-011/T-013 decoder harness. It stays `exported="true"` with `android:permission="android.permission.DUMP"`. The adb shell (`com.android.shell`) holds DUMP. DUMP is signature|privileged|development, so ordinary apps on the tablet cannot hold it, and their `startActivity` gets a SecurityException. Checked in the merged debug manifest. The adb launch itself needs the device (item 4 below).
- **Varsayımlar:**
  - Classes follow 0026/KNOBS.md, with one addition. `decoder_fault` + `decoder_fault_after_s` (T-159) were added after the 0026 inventory and are not in KNOBS.md. They are also treated as debug-only and gated, for two reasons: they have the same exposure (exported launcher, debuggable daily APK), and T-159 says "the extra itself is the gate until T-185 adds the developer switch". The `FLAG_DEBUGGABLE` check stays. → T-159/T-161/T-164 fault-injection commands now need `--ez dev true`.
  - The `net_bench_*` sub-keys are debug-only too, and appear in `ignored` if passed without `dev`. The `net_bench` value (host:port) is never logged.
  - `ignored=` separates keys with `,`. `knobs=` uses `key:value` joined by `;`, the same shape as the host `ev=profile` (T-204).
  - `knobs=` values are numbers or `0/1`. String knobs log a known id or `other`: `transport` auto/usb/wifi, `audio_out` auto/aaudio/track/audiotrack, `decoder_fault` modes. So an address typed into a string knob cannot reach the log. `net_bench*` never appears in `knobs=`. A key passed with its default value is still listed, as on the host.
  - `ev=profile` component is `session`. It is logged after `stream_config_bitrate` in `installConfig`, so once per STREAM_CONFIG: session start, mode/bitrate change, and any reconnect/migration that delivers a new config. Fields:
    - `transport=`: the current connection (`usb`/`wifi`, `-` if unknown).
    - `transport_mode=`: the setting or launch override in effect.
    - `audio=1`: audio is allowed and the panel setting is on.
    - `pacer=`: the current renderer buffer (game mode's buffer 0 shows as `buffer0`).
  - No `is_hw` (as the card says; it is in `ev=codec_start`).
  - Release unit tests (`testReleaseUnitTest`) would not see the bench classes. `NetBenchTest` compiles only in debug unit tests, and check.sh runs only `testDebugUnitTest`.
- **Test edilmeyenler / cihazda doğrulanacaklar** (orchestrator, one at a time):
  1. `adb shell am start -n dev.matebridge.client/.MainActivity --ei jitter 1`:
     - expect `I diag … ev=dev_knobs dev=0 ignored=jitter`, and at stream start `ev=profile … pacer=adaptive … dev=0 knobs=-`;
     - with `--ez dev true --ei jitter 1`: expect `dev_knobs dev=1 ignored=-` and `ev=profile … pacer=buffer1 … dev=1 knobs=jitter:1`.
  2. `--es net_bench <mac-ip>:5201`:
     - without `dev`: `ignored=net_bench`, normal session UI, no bench screen;
     - with `--ez dev true`: the NetBench screen ("Ağ ölçümü…") as before T-185.
  3. `ev=profile`:
     - each session start logs exactly one line, and its `sha=` equals `ev=app_start sha=`;
     - switching the display mode (e.g. Akıcı → Netlik) logs a new one with the new `mode=`/`fps=`;
     - the line contains no IP, port, serial or device id.
  4. `VideoTestActivity`:
     - `adb shell am start -n dev.matebridge.client/.debug.VideoTestActivity` still starts the test player (with `test.h265` pushed);
     - optional: `adb shell dumpsys package dev.matebridge.client | grep -A2 VideoTestActivity` shows `permission android.permission.DUMP`;
     - optional negative check: `adb shell run-as dev.matebridge.client am start -n dev.matebridge.client/.debug.VideoTestActivity` runs as the app uid (no DUMP) and should be refused with a permission denial, if `run-as am` works on HarmonyOS at all.
  5. Keep keys without `dev`:
     - `--ez stats_1s true` → `stats_log window_ms=1000`, `knobs=stats_1s:1`;
     - `--ez stall_diag true` → `stall_diag enabled=1`.
  6. Smoke: `--ez dev true --es audio_out track` → `audio_out_pref value=track source=extra`; without `dev` → `source=setting` and `ignored=audio_out`.
- **Açık sorular:**
  1. **`docs/LOGGING.md` (orchestrator).** Proposed text, as a new section after the client diag sections:

     ```
     ## Geliştirici kapısı ve akış profili (tablet, T-185, karar 0026)

     - `I diag ev=dev_knobs dev=0|1 ignored=<anahtar>[,<anahtar>…]|-`: `onCreate`'te bir kez yazılır.
       - `ignored`: `--ez dev true` verilmediği için yok sayılan "yalnızca geliştirici" anahtarları, `docs/KNOBS.md` sırasıyla.
       - Yalnız anahtar adları yazılır, değerler asla (`net_bench` adresi dahil). Biçim T-127 için sabittir.
     - `W diag ev=net_bench err=not_in_build`: `--ez dev true --es net_bench …` verildi ama bench etkinliği bu derlemede yok (debug kaynak seti olmayan derleme). Oturum normal başlar.
     - `I session ev=profile mode=<id> fps=<n> size=<w>x<h> scale_permille=<n> bitrate_kbps=<n> bitrate_setting=<n>|auto transport=usb|wifi|- transport_mode=auto|usb|wifi audio=0|1 audio_out=auto|aaudio|track pacer=adaptive|buffer<N> sha=<kısa SHA>[-dirty]|unknown built=<UTC>|unknown dev=0|1 knobs=<anahtar>:<değer>[;…]|-`
       - Uygulanan her `STREAM_CONFIG`'te (`installConfig`) bir kez yazılır, `stream_config_bitrate`'ten hemen sonra: oturum başında, mod ya da bit hızı değişiminde ve yeni config getiren her yeniden bağlanmada.
       - Alanların kaynağı:
         - `fps`, `size`, `bitrate_kbps`: STREAM_CONFIG.
         - `mode`, `scale_permille`: tablette seçilen mod.
         - `bitrate_setting`: tabletin ayarı (0 = `auto`).
         - `transport`: geçerli bağlantı. `transport_mode`: geçerli bağlantı modu ayarı ya da açılış geçersiz kılması.
         - `audio=1`: ses açık (`--ez audio false` verilmedi ve panel ayarı açık).
         - `pacer`: geçerli renderer tamponu (Oyun modunda `buffer0`).
         - `sha=`, `built=`: `ev=app_start` ile aynı kaynak (`BuildInfo`, T-146).
       - `knobs=`: dikkate alınan açılış ayarları, `docs/KNOBS.md` sırasıyla.
         - "Yalnızca geliştirici" ayarlar yalnız `dev=1` ile sayılır. "Kalır" sınıfı (`stats_1s`, `pace_trace`, `stall_diag`) her zaman sayılır.
         - Değer bir sayı, `0/1` ya da bilinen bir kimliktir. Bilinmeyen metin `other` yazılır.
         - `net_bench*` hiç yazılmaz. Varsayılana eşit verilen değer de listelenir.
       - `is_hw` yoktur (bkz. `ev=codec_start`, T-168). Uç nokta adresi, seri numarası ve cihaz kimliği asla yazılmaz.
     ```
     Also in the `decoder_fault` line (LOGGING.md:206): "(`--es decoder_fault …`)" → "(`--ez dev true --es decoder_fault …`)".
  2. **`docs/KNOBS.md` (orchestrator).**
     - "Sınıflar" / yalnızca geliştirici: append "(T-185 uygulandı: `DevKnobs.kt`; yok sayılan anahtarlar `diag ev=dev_knobs ignored=` satırında)".
     - New row after #23: `| 23b | --es decoder_fault create/configure/dequeue/silent, --ei decoder_fault_after_s N | yok; 10 | …/video/DecoderFault.kt:29-30; MA decoderFault | T-159 (bu envanterden sonra eklendi) | yalnızca geliştirici | Hata enjeksiyonu; FLAG_DEBUGGABLE + dev kapısı | T-185 |` (wrap the key names in backticks as in the other rows).
     - Row 23 `net_bench`: "Nerede" is now `client-android/app/src/debug/kotlin/…/bench/*`; the manifest entry is in `src/debug/AndroidManifest.xml`.
     - *Açık noktalar* 2: "Çözüldü (T-185): `VideoTestActivity` dışa açık kalır (adb `am start` için) ama `android:permission="android.permission.DUMP"` ile korunur; onu yalnızca adb kabuğu başlatabilir."
  3. The T-159/T-161/T-164 device procedures use `--es decoder_fault …`. After T-185 they also need `--ez dev true`. T-127 already covers its own rows.
