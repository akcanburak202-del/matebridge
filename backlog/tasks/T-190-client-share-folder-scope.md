---
id: T-190
title: Share a chosen folder (optional read-only) instead of all storage
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-153]
decisions: [0028]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesConfig.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/DavHandler.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/files/DavPath.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/files/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsCatalogTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsResetTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/FilesScopeSettingsTest.kt
  - backlog/tasks/T-190-client-share-folder-scope.md
---

## Amaç

Tablet file sharing serves the whole shared storage (`/sdcard`) read-write to the approved Mac. The user should be able to limit it to one chosen folder and, optionally, to read-only access, so that the Mac reaches only what was meant to be shared. "Tüm depolama" stays available as an explicit choice.

Source: external architecture review 2026-10-03 (M05, D9); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-6, scope part).
Decision 0028 must be accepted by the user before work starts (it amends decision 0015 item 1; manifest §5 Q7: default folder, keep "tüm depolama", offer read-only?).

## Bağlam

**Evidence at HEAD:**
- The root is the whole shared storage: `FilesController.startLocked` sets `val root = Environment.getExternalStorageDirectory()` (`FilesController.kt:83-85`, with the suppression comment citing decision 0015). `AndroidManifest.xml:8-11` requests `MANAGE_EXTERNAL_STORAGE`.
- There is no folder choice and no read-only mode. Sharing itself is off by default (`Settings.kt:51`; only a stored `"1"` enables it).
- The root is already a parameter all the way down: `DavServer` canonicalizes it (`DavServer.kt:100`) and hands it to `DavHandler` (`DavServer.kt:101-102`; `DavHandler.kt:26-28`). Every path goes through `DavPath.resolve(root, …)` (`DavPath.kt:110-123`). Segment checks (`.`, `..`, `/`, NUL, strict UTF-8; `DavPath.kt:26-48`) and the canonical/symlink check (`DavPath.kt:150-185`) are root-relative. So `DavPath.kt` should need no change beyond its tests; touch it only if a test shows a gap.
- Write methods are dispatched at `DavHandler.kt:97-106` (PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK). The AppleDouble/metadata branch (`DavHandler.kt:474-552`, `MetaStore`) has its own PUT/DELETE/MOVE/COPY/LOCK handling. `OPTIONS` answers `DAV: 1, 2` and `Allow: ALLOW` (`DavHandler.kt:86`, constant at `:652`). The storage is served under `/MatePad/` (`MOUNT`, `DavHandler.kt:88-89`, `:654`); `/` is the virtual root.
- The settings switch is wired through `SettingsHost`, which `MainActivity` implements (`SettingsCatalog.kt:59-64`, `:212`; `MainActivity.kt:907-911`). That is why `Settings.kt` and `MainActivity.kt` are in `files:` (the `SettingsHost` implementation and persistence only), although the manifest lists only the files package and `SettingsCatalog.kt`.
- `SettingsCatalogTest.kt` must change with any new `SettingsHost` member: its fake implements `SettingsHost` (`SettingsCatalogTest.kt:42-44`), it asserts the full key list (`:69`), and it asserts that "Tablet dosyaları" holds exactly `["files","files_status"]` (`:174`).

**Failure scenario (why):** any party holding the FILES_INFO token (today also an impostor host through H01, which T-150/T-153 close) gets read-write access to the entire shared storage: photos, downloads, documents. Narrowing the root limits the blast radius even when the token leaks.

**Plan hints:**
- Settings: a folder choice (for example `Download/`, a `MateBridge/` folder created on first use, or "Tüm depolama") and a read-only toggle, shown under "Tablet dosyaları". The default folder comes from the user's answer to §5 Q7. Do not use SAF / `ACTION_OPEN_DOCUMENT_TREE`: that is a rewrite and out of scope. A fixed list of choices under shared storage is enough. `MANAGE_EXTERNAL_STORAGE` is still needed for path access to a subfolder.
- Pass the chosen root into `DavServer` from `startLocked`. If the folder is missing and cannot be created, the server stays off and the status line says so; it never falls back to the whole storage.
- Read-only: add a flag (for example on `FilesConfig`) that `DavHandler` checks before dispatching. PUT, DELETE, MKCOL, MOVE, COPY, LOCK and UNLOCK get 403, including the metadata branch. In read-only mode `OPTIONS` answers `DAV: 1` (no class 2) and an `Allow` with the read methods only. macOS webdavfs mounts a server without class-2 locking read-only; with `Allow` limited but `DAV: 1, 2` Finder may still mount read-write and every write then fails with a generic error.
- A change of folder or read-only while the server runs restarts it: stop → new token → FILES_INFO OFF → READY. The Mac then remounts through the existing T-136 path.
- If T-191 has merged, add the folder and read-only keys to `Settings.resetToDefaults()` and to `SettingsResetTest`. (T-191 has the matching hint for the opposite order.)
- Logging: log the choice as a class (`root=download|matebridge|all ro=0|1`), never a full path or file names (AGENTS.md privacy).
- The lifetime gate (accepted, trusted USB session only) is T-153's work and is already in place when this card starts. Do not change `FilesSwitch`.
- **Serialize with T-146 and T-191 (same file `SettingsCatalog.kt`), and with T-191 on `session/Settings.kt`, `MainActivity.kt`, `SettingsCatalogTest.kt` and `SettingsResetTest.kt` (same files).** T-151 lists the `test/.../settings/` directory; it is ordered before this card through T-153. In the `MainActivity.kt` chain this card sits between T-153 and T-159, so keep the MainActivity edit to the `SettingsHost` members. (The orchestrator adds T-190 to the manifest §2 chains for `MainActivity.kt`, `SettingsCatalog.kt` and `Settings.kt`.)
- The orchestrator amends decision 0015 item 1 through decision 0028. FILES_INFO is unchanged, so there is no PROTOCOL.md change.
- **Risk:** Codex review is required (security, CLAUDE.md).

## Kapsam dışı

- A SAF/DocumentsProvider rewrite, and any Mac-side mount change (T-136).
- The server lifetime gate (T-153).
- Per-file permissions and multiple shared folders.

## Kabul kriterleri

- [ ] [JVM] A root other than `/sdcard` is honoured: PROPFIND of `/MatePad/` lists only the chosen folder's entries, and GET of a file in it works.
- [ ] [JVM] Escapes outside the chosen root are refused, extending `DavPathTest`/`DavServerTest`: `..` and encoded `%2e%2e`, an encoded `/`, NUL, invalid UTF-8, a `Destination` header pointing outside, and a symlink inside the root that points to a sibling folder of the root.
- [ ] [JVM] (If decision 0028 keeps read-only.) In read-only mode, PUT, DELETE, MKCOL, MOVE, COPY, LOCK and UNLOCK return 403, also for AppleDouble (`._*`) names, and nothing on disk changes. GET, HEAD, PROPFIND and OPTIONS still work, and `OPTIONS` answers `DAV: 1` (no class 2) with an `Allow` that lists only the read methods.
- [ ] [JVM] `FilesScopeSettingsTest`: the folder and read-only values persist (across a new `Settings` instance on the same map-backed store) and default as decision 0028 says. A missing folder keeps the server off; it never falls back to the whole storage.
- [ ] [JVM] `SettingsCatalogTest`: the "Tablet dosyaları" section lists `files`, the folder choice, read-only (if decision 0028 keeps it) and `files_status`.
- [ ] [device] The Finder mount shows only the chosen folder.
- [ ] [device] (If decision 0028 keeps read-only.) Finder shows the volume as read-only; copying a file onto the mount fails with a permission error and nothing appears on the tablet.
- [ ] [device] (If decision 0028 keeps "Tüm depolama".) Switching back to "Tüm depolama" shows the whole storage after the automatic remount.
- [ ] No full path or file name appears in any log line.
- [ ] Codex review (security) has no open findings.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

Decision 0028 (accepted 2026-10-03): default root `MateBridge/` (created if missing), `Download/` and "Tüm depolama" as choices, read-only offered (default off).

1. `files/FilesConfig.kt`: `readOnly: Boolean = false` on `FilesConfig`; new pure `FilesRoot` enum (`matebridge` default, `download`, `all`; unknown stored value → default) and `FilesScope(root, readOnly)` with `directory(storage)`: storage itself only for `all`; otherwise `storage/<folder>`, created when missing, and null when it is not a real directory directly under the storage (file, symlink, mkdir failed) — never a fallback to the whole storage. `logFields()` = `root=<id> ro=0|1`; status text for a missing folder.
2. `files/DavHandler.kt`: read-only gate after auth and OPTIONS: PUT, DELETE, MKCOL, MOVE, COPY, LOCK, UNLOCK → 403 before any dispatch (covers the virtual root and the `._*` metadata branch). OPTIONS answers `DAV: 1` and `Allow` with the read methods only; every `405 Allow` uses the same list.
3. `files/FilesController.kt`: a `scope` provider read at every server start; the factory resolves the directory, logs `ev=scope root= ro=`, and when the folder is missing builds a server that fails at once (OFF + FAILED, status text names the folder problem). `rescope()`: when the scope differs from the running server's, stop (OFF) and start again with the last sync inputs (new token, READY on listen). `statusText`.
4. `session/Settings.kt`: `files_root` / `files_read_only` keys, `filesRoot()`, `filesReadOnly()`, `filesScope()`.
5. `settings/SettingsCatalog.kt`: `SettingsHost` gets `filesRoot`/`selectFilesRoot`, `filesReadOnly`/`setFilesReadOnly`; "Tablet dosyaları" = `files`, `files_root` (Choice), `files_ro` (Toggle), `files_status`.
6. `MainActivity.kt`: only the `SettingsHost` members, the `FilesController` constructor argument and the status text.
7. Tests: `files/DavScopeTest.kt` (server on a sub-folder root: listing, GET, escapes incl. symlink to a sibling and `Destination` outside, read-only matrix incl. `._*`), `files/FilesScopeTest.kt` (directory rules, lifecycle with a missing folder never publishes READY), `session/FilesScopeSettingsTest.kt`, `SettingsCatalogTest.kt`. T-191 is not merged: no `SettingsResetTest` change.

Risks: `FilesLifecycle.kt` is not in `files:`, so a scope restart goes through `shutdown()` (its log line says `reason=destroy`, preceded by `ev=scope_change`); PROPFIND still advertises `supportedlock` in read-only mode (`DavXml.kt` not in `files:`).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
