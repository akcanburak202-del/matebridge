---
id: T-153
title: Run the WebDAV server only during an accepted, trusted USB session
status: todo
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

- [ ] [JVM] `FilesSwitch.shouldRun` is true only when the app is in the foreground, the setting is on, the permission is granted, the session is trusted (authenticated STREAM_CONFIG applied on the current session), and `transport == USB`; every other combination is false (table test). `Connected` without such a STREAM_CONFIG is not trusted.
- [ ] [JVM] `FilesLifecycle` (fake server factory and publisher): a session end, a loss of the trusted signal, or a switch to Wi-Fi stops the server; OFF is published before the stop, and the next start publishes a different token.
- [ ] [JVM] The idle status text distinguishes "not on a trusted USB session" from "app not in the foreground", "setting off" and "no permission".
- [ ] [device] With sharing on: on Wi-Fi the server never starts (`state=off`, no `state=on`); unplugging USB during a session → `state=off`; replugging → a new token and the Finder mount works.
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
