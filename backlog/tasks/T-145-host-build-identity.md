---
id: T-145
title: Log and show the host build commit
status: done
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - scripts/bundle-host.sh
  - host-mac/Resources/Info.plist
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeCore/Session/BuildInfo.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/BuildInfoTests.swift
  - backlog/tasks/T-145-host-build-identity.md
---

## Amaç

Nothing on the Mac says which commit is running: the host log, the menu and the NOTES session hand-offs only carry times ("tablet APK 12:49"). Measurements, soak runs, the recovery runbook (T-147) and bug reports must name an exact build. After this card every host log starts with one `app_start` line carrying the commit SHA and build time, and the menu shows the same SHA.

Source: external architecture review 2026-10-03 (L01, D1, M07); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (BUILDID-H, L01).

## Bağlam

- **Evidence (HEAD a30c769):**
  - `scripts/bundle-host.sh:66-69` already injects a build timestamp: `build_number=$(date +%Y%m%d%H%M%S)` replaces `__BUILD__` in `host-mac/Resources/Info.plist:24-25` (`CFBundleVersion`). `CFBundleShortVersionString` is a fixed `0.1` (`Info.plist:22-23`). No commit is written anywhere.
  - No host code reads `CFBundleVersion` or `infoDictionary` (grep is empty). The first log line of a run is `listening` (`host-mac/Sources/MateBridgeHost/Session/SessionServer.swift:1068-1071`), which carries transport knobs, not a version.
  - HELLO carries only `protocol_version`; an app version on the wire would be a protocol change and is **not** part of this card.
- **Plan hints:**
  - `bundle-host.sh`: add an `MBGitCommit` placeholder to `Info.plist` and fill it with `git rev-parse --short HEAD`, plus `-dirty` when `git status --porcelain` is non-empty; `unknown` when git or `.git` is missing. Keep `plutil -lint` passing.
  - `BuildInfo` (Core, pure): built from a `[String: Any]` dictionary (`Bundle.main.infoDictionary` in the app, a literal in tests). Fields `version`, `build`, `sha`; a missing key becomes `unknown`. Provide `logFields(os:)` so the line format is tested in Core.
  - `main.swift`: log `ev=app_start version=<CFBundleShortVersionString> build=<CFBundleVersion> sha=<MBGitCommit> os=<ProcessInfo.operatingSystemVersionString>` once, through `HostLog.log` (it writes both os.Logger and `~/Library/Logs/MateBridge/host.log`; the private `log()` in `main.swift:350-354` only reaches os.Logger), **before** `server.start()` (`main.swift:178`). Add a disabled "Sürüm 0.1 (<sha>, <build>)" item to the menu built at `main.swift:51-94`.
  - No serial number, user name or host name in the line.
- **Risks:** a `swift run` binary has no bundle Info.plist, so `infoDictionary` lacks the keys; that must yield `unknown`, never a crash.
- **Serialize with:** T-167, T-189 and T-192 (same file `main.swift`; chain T-145 → T-167 → T-189 → T-192). T-145 goes first.
- **Docs:** `docs/LOGGING.md` gets the new `app_start` line from the orchestrator; list it under *Açık sorular*.
- No wire change; `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- Client side (T-146), any protocol field, notarization or release signing.
- The README "last verified pair" text (T-193).

## Kabul kriterleri

- [x] [XCTest] `BuildInfoTests`: a full Info.plist dictionary gives the right `version`, `build` and `sha`; each missing key becomes `unknown`; `logFields` produces exactly `version=… build=… sha=… os=…`.
- [ ] [device] (Mac) `bundle-host.sh` writes `MBGitCommit` (short SHA, `-dirty` on a dirty tree, `unknown` without git); `plutil -lint` still passes.
- [ ] [device] `swift run` (no bundle) logs `ev=app_start … sha=unknown` and does not crash.
- [ ] [device] A bundled `MateBridge.app` logs exactly one `ev=app_start version= build=<CFBundleVersion> sha=<MBGitCommit> os=` line per launch in `host.log`, before `listening`, and the menu shows the same SHA on a disabled "Sürüm …" line.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. `host-mac/Resources/Info.plist`: add `MBGitCommit` = `__GIT_COMMIT__` placeholder (template comment updated).
2. `scripts/bundle-host.sh`: compute `git_commit` from the repo root: `git rev-parse --short HEAD`, `-dirty` suffix when `git status --porcelain` is non-empty, `unknown` when git is missing, the tree is not a repo, or the command fails. Substitute it with `sed`; `plutil -lint` stays.
3. `MateBridgeCore/Session/BuildInfo.swift` (pure): `BuildInfo(infoDictionary: [String: Any]?)` with `version` (`CFBundleShortVersionString`), `build` (`CFBundleVersion`), `sha` (`MBGitCommit`). Missing key, non-string, empty or an unfilled `__X__` placeholder → `unknown`. `logFields(os:)` → `version=… build=… sha=… os=…`; whitespace inside a value becomes `_` so the line stays `key=value` parseable (`operatingSystemVersionString` contains spaces). `menuTitle` → `Sürüm <version> (<sha>, <build>)`.
4. `MateBridgeApp/main.swift`: at the top of `applicationDidFinishLaunching` (before `server.start()`), build `BuildInfo(infoDictionary: Bundle.main.infoDictionary)`, log `ev=app_start` once via `HostLog.log(.info, component: "session", …)`, and add a disabled `menuTitle` item to the menu.
5. `Tests/MateBridgeCoreTests/Session/BuildInfoTests.swift`: full dictionary, each missing key, nil dictionary, placeholder/empty values, exact `logFields` output, whitespace sanitising, `menuTitle`.
6. `./scripts/check.sh`; a local `bundle-host.sh` run only to inspect the generated Info.plist (no app launch).

Risks: `swift run` has no bundle Info.plist → every field `unknown` (covered by the nil/empty dictionary test). Serialize with T-167/T-189/T-192 on `main.swift`: keep the diff small.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:** `6ac48ad` (implementation), plan `87f3ef8`; this Handoff is in the branch's last commit. Branch `task/T-145-host-build-identity`. `./scripts/check.sh` → ALL OK (host-mac 342 tests, 8 new `BuildInfoTests`).
- **Dokunulan dosyalar:** `scripts/bundle-host.sh`, `host-mac/Resources/Info.plist`, `host-mac/Sources/MateBridgeApp/main.swift`, `host-mac/Sources/MateBridgeCore/Session/BuildInfo.swift` (new), `host-mac/Tests/MateBridgeCoreTests/Session/BuildInfoTests.swift` (new), this card.
- **Varsayımlar:**
  - Line: `I session sid=0 gen=0 ev=app_start version=0.1 build=<CFBundleVersion> sha=<MBGitCommit> os=<…>`, logged via `HostLog.log` as the first statement of `applicationDidFinishLaunching` (so before `server.start()` and its `listening` line). The CLI modes (`--dump-video` etc.) exit earlier and log no `app_start`.
  - Whitespace and `=` inside a value become `_` so every field stays one `key=value` token; `operatingSystemVersionString` therefore logs as e.g. `os=Version_27.0_(Build_27A…)`.
  - A missing key, non-string, empty value or an unfilled `__X__` template placeholder → `unknown`.
  - The disabled `Sürüm 0.1 (<sha>, <build>)` line sits just above `Quit` (after the last separator), not at the top.
  - `-dirty` comes from `git status --porcelain` at the repo root, so untracked (non-ignored) files also mark the build dirty. The SHA is the repo's HEAD, also for probes bundled with `--package`.
  - Bundle script prints `==> build <n>, commit <sha>`.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - Done locally (no launch): `bundle-host.sh --out <scratch>` on a clean tree → `MBGitCommit=6ac48ad`, with an untracked file → `6ac48ad-dirty`; `plutil -lint` OK on both.
  - Not tested: the `unknown` path when git or the repository is missing (sandbox would not allow a git-less run).
  - Not tested (no app launch allowed): `swift run` logging `sha=unknown` without crashing; a bundled `MateBridge.app` writing exactly one `app_start` line before `listening` in `~/Library/Logs/MateBridge/host.log`; the menu showing the disabled `Sürüm …` line with the same SHA.
- **Açık sorular:**
  - `docs/LOGGING.md` needs the new `ev=app_start version= build= sha= os=` line (orchestrator), including the `_` substitution for spaces in `os`.
