---
id: T-153
title: Run the WebDAV server only during an accepted, trusted USB session
status: done
phase: 6
owner: android-client-dev
depends_on: [T-151]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesSwitch.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesLifecycle.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/files/
  - backlog/tasks/T-153-client-files-session-lifetime.md
---

## Amaç

The tablet's WebDAV file server (decision 0015) listens on `127.0.0.1` whenever the app is in the foreground and sharing is on, whether or not a Mac is connected, and over any transport. The Mac can only mount it over USB, so for most of that time the token-protected listener serves nobody but is reachable by every app on the tablet. After this card the server runs only while a session is accepted **and** locally trusted (T-150) **and** runs over USB; any session end or switch to Wi-Fi stops it and invalidates its token. Together with T-150 this closes the local-app path to shared storage that broke decision 0015 item 3.

Source: external architecture review 2026-10-03 (M05); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-6 lifetime part, additional issue A4, M05 correction 1) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§2).
Decision 0018 must be accepted by the user before work starts (the "locally trusted" condition comes from it).

## Bağlam

`C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`. Lines are at HEAD a30c769.

- **Evidence:**
  - `C/files/FilesController.kt:39-47` `sync(enabled, foreground)`: runs the server when `FilesSwitch.shouldRun(enabled, permission, foreground)` (`C/files/FilesSwitch.kt:14` = `enabled && permission && foreground`). No session or transport term.
  - A new 128-bit token per server start (`FilesController.kt:79-82`; `FilesSwitch.newToken` :33-36); READY with the token is published as soon as the socket listens (:92-99), OFF before a stop. The root is all shared storage (:83-85; narrowing that is T-190).
  - MainActivity call sites: `files.sync(...)` at `C/MainActivity.kt:911` (setting toggle), `:1490` (onStart, foreground = true) and `:1780` (onStop, foreground = false). The session state reaches `render()` (:1859-1890); the transport is `ConnectMode.transportOf(currentEndpoint)` / `isOnUsb()`.
  - FILES_INFO itself is sent "once per session, after AUDIO_PREFS, then on change" (`C/session/SessionMachine.kt:264-270`, `:310`) and, after T-150, only on a locally trusted session. A server that starts after the session is accepted therefore reaches the Mac through the existing "on change" path; no machine change is needed.
- **Why it matters:** A2 §2 showed a tablet app squatting `127.0.0.1:47001` could obtain the token through H01 and then read/write all of `/sdcard`. T-150 removes the token leak; this card removes the always-on listener so a token, even if obtained, is useful only during a trusted USB session.
- **Plan hints:**
  - `FilesSwitch.shouldRun(enabled, permission, foreground, sessionTrusted, transport)`: true only for `enabled && permission && foreground && sessionTrusted && transport == USB`.
  - **Trusted signal:** a STREAM_CONFIG authenticated and applied on the **current** session (current connection generation), not `lastUi is SessionUi.Connected` alone. A PAIRED connection still emits `Connected` at the **plaintext** ack, before any host record authenticated (`SessionMachine.kt:302-317`; residual kept by T-150), so `Connected` alone would start the listener with a fresh token for an unauthenticated PAIRED peer. STREAM_CONFIG is sealed, and after T-152 the host sends it only after the proof.
  - **Testable lifecycle:** `FilesController` depends on `android.os.Build`, `Environment` and `Process` (`FilesController.kt:37`, `:84`, `:86`) and the project has no Robolectric (`build.gradle.kts:37`, junit only). Put the start/stop decision and the publish order (OFF before stop; a new token per start) in a new pure `C/files/FilesLifecycle.kt` over an injected server factory and publisher; `FilesController` delegates to it.
  - One new call from `render()` (or one helper it calls) when the accepted state or the transport changes; the three existing call sites pass the extra inputs. No other MainActivity change.
  - A stop must publish OFF before the server stops (existing order) and the next start must use a new token (existing per-start token).
  - New idle states for the status line (`FilesSwitch.statusText`, :23-30), e.g. "Durum: Mac'e USB ile bağlanınca açılır" instead of the misleading "uygulama ön planda değil".
  - AUTO migration Wi-Fi → USB starts the server after promotion; USB → Wi-Fi fallback stops it.
- **Serialize with:** T-159 (same file `MainActivity.kt`; chain T-146 → T-150 → T-151 → T-153 → T-159 → …) and T-156 (both depend on T-151 and both edit `MainActivity.kt`). T-190 (folder scope) follows this card in `FilesController.kt` and the `test/.../files/` directory, and must build on `FilesLifecycle.kt`.
- No wire change; FILES_INFO semantics are unchanged (start/stop timing is already allowed by PROTOCOL §0x09). `docs/LOGGING.md` additions (if any) go under *Açık sorular*.

## Kapsam dışı

- Folder scope and read-only mode (T-190, decision 0028); Mac-side mount changes; DAV server internals.

## Kabul kriterleri

- [x] [JVM] `FilesSwitch.shouldRun` is true only when the app is in the foreground, the setting is on, the permission is granted, the session is trusted (authenticated STREAM_CONFIG applied on the current session), and `transport == USB`; every other combination is false (table test). `Connected` without such a STREAM_CONFIG is not trusted.
- [x] [JVM] `FilesLifecycle` (fake server factory and publisher): a session end, a loss of the trusted signal, or a switch to Wi-Fi stops the server; OFF is published before the stop, and the next start publishes a different token.
- [x] [JVM] The idle status text distinguishes "not on a trusted USB session" from "app not in the foreground", "setting off" and "no permission".
- [ ] [device] With sharing on: on Wi-Fi the server never starts (`state=off`, no `state=on`); unplugging USB during a session → `state=off`; replugging → a new token and the Finder mount works.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. `files/FilesSwitch.kt`: `shouldRun(enabled, permission, foreground, sessionTrusted, transport)` = all true and `transport == USB`; `idleStatus(...)` gets a new `FilesStatus.NO_USB_SESSION` ("Durum: Mac'e USB ile bağlanınca açılır"), checked after setting/permission/foreground; `stopReason(...)` for the `server state=off reason=` log (`disabled`, `no_permission`, `background`, `no_session`, `wifi`).
2. `files/FilesLifecycle.kt` (pure, JVM-tested):
   - `FilesSessionGate`: trust signal per connection generation. `onConnectionGen(gen, transport)` (from `SessionListener.onConnectionGen`, which carries the connection's own transport), `onConfigApplied()` (from `installConfig`, i.e. an authenticated STREAM_CONFIG applied on the current generation), `onUi(connected)`. `trusted` = Connected and config applied on the current gen; a new gen (reconnect or migration) or any non-Connected state drops it. Each call returns whether (trusted, transport) changed, so MainActivity syncs only on change (render() runs every 250 ms).
   - `FilesLifecycle<S>`: the start/stop logic moved out of `FilesController` over an injected server factory, token source, publisher and log: one server at a time, a new token per start, READY only from `onListening` of the live generation, OFF published under the lock before `stop()`, failed server → FAILED + OFF, retired server handed to the next start.
3. `files/FilesController.kt`: `sync(enabled, foreground, sessionTrusted, transport)` reads the permission and delegates to `FilesLifecycle`; the factory builds `DavServer` (root, hooks, thread priority, MbLog) as today.
4. `MainActivity.kt`: one `FilesSessionGate` field and one `syncFiles(foreground)` helper; gate calls in `onConnectionGen` (UI block), `installConfig` and `render()`; the three existing `files.sync` call sites go through the helper.
5. Tests in `test/.../files/`: `shouldRun` table over all 48 combinations (4 booleans × USB/Wi-Fi/none), idle status/reason, gate (Connected without STREAM_CONFIG, stale gen, migration, Wi-Fi), lifecycle with fakes (OFF before stop, new token per start, stale callbacks ignored, failure).

Risks: ordering of UI-thread posts (onConnectionGen, Ui, ApplyConfig all come from the engine thread in order, so FIFO keeps gen and config consistent); T-205 edits SessionMachine/Controller in parallel — not touched here.

## Handoff

- **Commit:** `0559b3a` (implementation; plan: `d92a48e`), branch `task/T-153-client-files-session-lifetime`. `./scripts/check.sh` → ALL OK (FilesLifecycleTest 15/15).
- **Dokunulan dosyalar:**
  - `C/files/FilesLifecycle.kt` (new): `FilesSessionGate` (trust per connection generation) and `FilesLifecycle<S>` (start/stop, token per start, OFF-before-stop, stale callbacks ignored, failure → FAILED + OFF; logic moved unchanged from `FilesController`).
  - `C/files/FilesSwitch.kt`: `shouldRun(enabled, permission, foreground, sessionTrusted, transport)`, `idleStatus(enabled, permission, foreground)`, new `FilesStatus.NO_USB_SESSION` ("Durum: Mac'e USB ile bağlanınca açılır"), `stopReason(...)`.
  - `C/files/FilesController.kt`: `sync(enabled, foreground, sessionTrusted, transport)` delegates to `FilesLifecycle`; the factory builds `DavServer` as before (root, thread priority, hooks).
  - `C/MainActivity.kt`: `filesGate` field + `syncFiles()` helper; gate calls in `onConnectionGen` (UI block), `installConfig`, top of `render()` (sync after the started check, only on a gate change); the three existing call sites (setting toggle, onStart, onStop) pass the new inputs.
  - `test/.../files/FilesLifecycleTest.kt` (new), `test/.../files/FilesLogicTest.kt` (old 3-arg switch test moved into the new file).
- **Varsayımlar:**
  - Trusted = rendered `Connected` **and** `installConfig` ran on the current connection generation. `installConfig` is reached only via `Action.ApplyConfig`, which the machine emits only in ACCEPTED/STREAMING (after T-150 local trust) for a sealed STREAM_CONFIG. `onConnectionGen`, `onUi` and `onStreamConfig` are all posted from the engine thread in order, so the UI-thread FIFO keeps the config bound to its generation. A migration's promoted candidate is a new generation, so trust drops at the switch and comes back only with that connection's own STREAM_CONFIG.
  - The transport is the one `SessionListener.onConnectionGen(gen, transport)` reports for the connection itself, not `currentEndpoint` (which `onMigrationResult` may leave stale when `migrateEpoch != transportEpoch`).
  - onStart passes `sessionTrusted = false, transport = null` explicitly: `onStop` stopped the controller, so no session can be trusted there even if the old session's Idle render has not arrived yet (the following `render(Searching)` clears the gate anyway).
  - Status order: DISABLED > NO_PERMISSION > PAUSED (background) > NO_USB_SESSION.
- **Test edilmeyenler / cihazda doğrulanacaklar:** (no tablet used)
  1. Sharing on, **Wi-Fi** session: `adb logcat -s 'MB/files:*'` shows no `ev=server state=on`; the status line reads "Durum: Mac'e USB ile bağlanınca açılır".
  2. **USB** session: `ev=server state=on port=…` only after the video starts (STREAM_CONFIG), then `files_info_sent state=1` on the session tag; the Finder mount works.
  3. Unplug USB during the session → `ev=server state=off port=0 reason=no_session` (or `reason=wifi` if AUTO migrates to Wi-Fi while the session stays up); the status goes back to the USB hint.
  4. Replug (AUTO Wi-Fi → USB migration or reconnect) → a new `state=on`; the Mac remounts with the new token.
  5. A connection that stays `Connected` without video never logs `state=on`; toggling the setting off/on during a USB session stops/starts the server; background → `reason=background`.
- **Açık sorular:**
  - `docs/LOGGING.md` has no entry for the `files` component's `ev=server state=on|off port= reason=` line. New `reason=` values from this card: `no_session` (no trusted session) and `wifi` (trusted session on Wi-Fi); existing: `disabled`, `no_permission`, `background`, `destroy`, `failed`, `ended`. The orchestrator may add them.
  - T-205 (migration auth gate, parallel) changes how a migrated connection is accepted; this card relies only on the `onConnectionGen` → `ApplyConfig` ordering on the engine thread, which T-205 should keep.
