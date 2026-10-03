---
id: T-191
title: Add "Varsayılanlara dön" (settings + learned audio state; pairing kept)
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-185]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/SharedPrefsOutBufStore.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/SharedPrefsSafetyStore.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/OutBufMemory.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/SafetyMemory.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/AudioPlayout.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsResetTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsCatalogTest.kt
  - backlog/tasks/T-191-client-settings-reset.md
---

## Amaç

The tablet app has no way back to a known-good configuration short of Android "clear data", and that also deletes the pairing keys. Learned audio state can be pushed up by an experiment and only ever ratchets up. One panel action, "Varsayılanlara dön", should restore every user setting to its default and clear the learned audio state, while keeping pairing, the device identity and the learned wake data. This is part of the known-good recovery path (D9).

Source: external architecture review 2026-10-03 (D9); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (RESET-C, additional issue 4).

## Bağlam

**Evidence at HEAD:**
- Settings live in the `matebridge` SharedPreferences file through `KeyValueStore` (`Settings.kt:6-10`; adapter at `MainActivity.kt:454-458`). The user-setting keys are in `Settings.kt:138-151`: `stats_overlay`, `stream_mode`, `bitrate_kbps`, `touchpad_speed`, `mouse_speed`, `clipboard_share`, `files_share`, `audio_enabled`, `audio_out`, `pen_trail`, `pen_dot`, `finger_touch_disabled`, `transport`.
- The same file also holds state the reset must **keep**:
  - `device_id` (`Settings.kt:15-23`), the host's approval of this tablet;
  - `last_endpoint` (`Settings.kt:25-27`);
  - `transport_auto_migrated` (`Settings.kt:85-91`), so the T-096 migration does not run again;
  - the learned Wake-on-LAN data `wol_macs`, `wol_host`, `wol_port`, `wol_subnet` (`WolStore`, `session/Wol.kt:193-221`).
  
  So the reset removes an explicit key list. It must not clear the whole file.
- Pairing keys are in the separate `matebridge_pairkeys` file (`MainActivity.kt:474-478`) and are never touched.
- Learned audio state is in `matebridge_audio`: `out_buf_bursts_<path>` (`SharedPrefsOutBufStore.kt:6-22`) and `safety_ms_<key>` (`SharedPrefsSafetyStore.kt:9-25`). `OutBufMemory` only ratchets up, and an `--ei audio_buf_bursts` experiment override can push it (`audio/AudioBufferConfig.kt:14`, `audio/OutBufMemory.kt:16`; T-110 card :127).
- Clearing SharedPreferences alone does not reset learned audio state within the same activity. `OutBufMemory` caches stored values in memory (`OutBufMemory.kt:23`, `:42-48`), and `SafetyMemory` keeps `lastSaved` per key (`SafetyMemory.kt:44`, `:76-79`). `AudioPlayout` owns both memories (`AudioPlayout.kt:86-88`) and is created once per activity (`MainActivity.kt:491`). A live stream calls `SafetyMemory.onSafety` about once per second and `OutBufMemory.onGrown` on growth, so it can store a learned value again after a store-only clear. The next session in the same activity would then still log `buf_source=stored`.
- The store interfaces `OutBufStore`/`SafetyStore` have test fakes outside `files:` (`OutBufMemoryTest.kt:10`, `:109`; `SafetyMemoryTest.kt:11`, `:139`; `SafetyTransportTest.kt:13`). The SharedPrefs implementations are Android-only, and the project has no Robolectric.
- The effect is visible in the `audio_out` log line: `source=` / `stored_ms=` for safety and `buf_source=` / `buf_stored=` for the buffer (`AudioPlayout.kt:380-387`; `OutBufMemory.SOURCE_DEFAULT = "default"`, `OutBufMemory.kt:57`).

**Failure scenario (why):** after an `audio_buf_bursts` experiment, or a bad run of underruns, every later session starts with an enlarged audio buffer (more latency). The only fix today is "clear data", which also unpairs the tablet and forces a new approval on the Mac.

**Plan hints:**
- `KeyValueStore` has no `remove`. T-151 ("Bu Mac'i unut") may already add one; reuse it if so. Otherwise add `remove(key)` as an interface method **with a default body**, or the 9 test fakes under `client-android/app/src/test/` stop compiling, and they are outside `files:`. If a default body is not acceptable, write it under *Açık sorular*.
- Learned audio state: `AudioPlayout.forgetLearned()` clears both memories' caches and their stores. If a stream is live, the clear is applied at the next stream start (a pending flag), so the running writer cannot store the old value again. Add `clear()` to `OutBufStore`/`SafetyStore` **with a default body** (the fakes above must keep compiling), or add it only to the memories. Test it through the memories with a map store in `SettingsResetTest`; the SharedPrefs implementations are covered by the [device] step.
- `Settings.resetToDefaults()` removes the user-setting key list (including any keys T-190 adds for the shared folder and read-only, if T-190 merged first). It is pure and JVM-testable with a map-backed store.
- The panel entry goes in the "Diğer" section of `SettingsCatalog`, with a 2-step confirm: a first tap arms it, a second tap within a few seconds performs it. Keep the arming state in a pure helper so `SettingsCatalogTest` can test it (no dialog: it is not JVM-testable).
- `MainActivity` applies the defaults live through the existing `SettingsHost` setters (mode, bitrate, transport, audio, input, overlay, clipboard, files), so a live session follows. A 60↔120 mode change may recreate the display once (decision 0016). Cleared audio state takes effect at the next audio stream start; say so in a toast.
- Log `ev=settings_reset` once, with no values (at most a count of keys removed).
- **Serialize with T-146 and T-190 (same file `SettingsCatalog.kt`), with T-190 on `Settings.kt`, `MainActivity.kt`, `SettingsCatalogTest.kt` and `SettingsResetTest.kt`, with T-151 (lists the `test/.../settings/` directory), and with T-185 on `AudioPlayout.kt` (same file; already a dependency).** In the `MainActivity.kt` chain the order is T-185 → T-191 → T-197.
- `depends_on: [T-185]` only serializes `MainActivity.kt`/`AudioPlayout.kt`. If T-185 is closed as won't-do, drop it from `depends_on`.

## Kapsam dışı

- Pairing keys, `device_id`, `last_endpoint`, `transport_auto_migrated`, WoL data and the T-185 developer profile (launch extras are never stored).
- Host-side settings (T-192).
- Changing any default value.

## Kabul kriterleri

- [ ] [JVM] Reset also clears T-190's `files_root` (back to the default `matebridge`) and `files_read_only` (back to off). Added by the orchestrator 2026-10-03.
- [ ] [JVM] `SettingsResetTest`: with every user setting set to a non-default value, `resetToDefaults()` makes every getter return its default.
- [ ] [JVM] `SettingsResetTest`: `device_id`, `last_endpoint`, `transport_auto_migrated`, the `wol_*` keys and the separate pair-key store (`matebridge_pairkeys`) are untouched, byte for byte.
- [ ] [JVM] `SettingsResetTest` (map-backed stores): the audio clear removes every stored buffer and safety value, and afterwards `OutBufMemory` and `SafetyMemory` start from their defaults (`SOURCE_DEFAULT`, `source=default`).
- [ ] [JVM] After the clear, the same `OutBufMemory` instance (with a cached value) returns `SOURCE_DEFAULT`.
- [ ] [JVM] `SettingsCatalogTest`: the "Varsayılanlara dön" item exists and needs two steps; one tap alone resets nothing, and the armed state expires (pure helper, fake clock).
- [ ] [device] (logcat) Exactly one `ev=settings_reset` line per reset, with no setting values.
- [ ] [device] Precondition: a session whose `audio_out` line shows `buf_source=stored` (or safety `source=stored`). If the tablet has no learned state yet, start once with a small `--ei audio_buf_bursts 1` until `audio_buffer_grow` is logged, then restart without the extra. Note: the override alone stores nothing; only growth does (`OutBufMemory.onGrown`). Reset (also once while a stream is live), start a session in the same activity, and the `audio_out` line shows `buf_source=default buf_stored=-` and `stored_ms=-`.
- [ ] [device] After a reset, the tablet reconnects to the Mac with no approval prompt (pairing kept). The panel shows Akıcı, Otomatik bitrate and the AUTO transport.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `Settings.kt`: `KeyValueStore.remove(key)` with a default body (throws `UnsupportedOperationException`; the 9 test fakes keep compiling). `Settings.resetToDefaults(): Int` removes only the explicit user-setting key list (13 keys + T-190 `files_root`, `files_read_only`) and returns how many were present. `device_id`, `last_endpoint`, `transport_auto_migrated`, `wol_*` and the pair-key file are never named.
2. Audio: `OutBufStore.clear()` / `SafetyStore.clear()` with a default body (throws; the fakes keep compiling). `OutBufMemory.clear()` / `SafetyMemory.clear()` drop the in-memory caches (`stored`, `lastSaved`, save timer) and clear the store (false if the store failed). SharedPrefs stores remove their own key prefix (`out_buf_bursts_`, `safety_ms_`) in `matebridge_audio`. `AudioPlayout.forgetLearned()` clears now and sets a pending flag; the next stream's writer (after it has waited for the previous writer) clears again before its first `initial()`, so a live writer's later save cannot survive into the next session.
3. `SettingsCatalog.kt`: pure `TwoTapConfirm` (fake clock; the first tap arms, a second tap within `WINDOW_MS` confirms, after that it is a new first tap). `SettingsHost` gets `resetConfirm`, `onResetArmed()`, `resetToDefaults()`. "Diğer" gets the `reset_defaults` Action plus a `reset_hint` Info that shows the armed state (`SettingsViews.kt` is not in `files:`, and an Action's title is fixed).
4. `MainActivity.kt`: SharedPreferences adapter gets `remove`. The reset removes the keys, clears audio learning, then applies the defaults live without writing them back where possible (mode + STREAM_PREFS with the default bit rate, game layer dropped; audio output; audio on/off to the host when it changed; pointer speeds; fingers; pen trail/dot; clipboard; stats; files sync + rescope), transport through `selectTransport(AUTO)` only when it differs. One `ev=settings_reset keys=<n>` line, then a toast. On arming it posts a refresh so the hint goes away when the window expires.
5. Tests: `SettingsResetTest` (new) and `SettingsCatalogTest` (FakeHost + the two-step item).

Risks: a previous writer that takes longer than `PREVIOUS_JOIN_MS` to finish could still save after the start-time clear (the same limit already exists for the output). The transport reset re-writes `transport=auto` through the existing setter (a default value).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
