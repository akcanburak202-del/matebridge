---
id: T-202
title: Relaunch the host after a crash (LaunchAgent with KeepAlive)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-147, T-148]
decisions: []
files:
  - host-mac/Sources/MateBridgeApp/LoginItem.swift
  - host-mac/Sources/MateBridgeCore/Session/LoginItemPolicy.swift
  - host-mac/Resources/LaunchAgent.plist
  - scripts/bundle-host.sh
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-202-host-crash-restart-agent.md
---

## Amaç

**Gated: start only after (1) T-147's "host quit or crash" rehearsal is recorded in docs/NOTES.md and shows a need: with the tablet as the only screen, relaunching the host failed, or needed a second device or remote path the user does not always have at hand, or took longer than 2 minutes; (2) the user answers manifest §5 Q11 with "the host should relaunch itself"; and (3) the orchestrator has drafted the crash-restart decision (deferred, number assigned when drafted) and the user has accepted it. If the rehearsal shows a manual relaunch is quick and reliable, this card is closed as won't-do.**

On a headless Mac where the tablet is the only screen, a host crash or SIGKILL leaves the Mac unreachable from the tablet until the next login or a manual `open` through Parsec/SSH. Registering the host as a LaunchAgent with `KeepAlive {SuccessfulExit: false}` relaunches it within seconds after a crash, while a clean Quit stays quit. The tablet then reconnects on its own.

Source: external architecture review 2026-10-03 (M06, SE5); verification: docs/reviews/2026-10-03/verify-D-display.md.
The crash-restart decision (deferred; drafted after T-147) must be accepted by the user before work starts.

## Bağlam

**Evidence (HEAD a30c769):**
- Start at login is `SMAppService.mainApp` only (`LoginItem.swift:5-6, 58`); there is no crash supervisor and no KeepAlive anywhere (repo grep, D M06).
- SIGINT/TERM/HUP are routed to a clean terminate (`main.swift:97-104`), so a clean exit is status 0. A crash or SIGKILL leaves the host down. The virtual display is process-owned and disappears with the process (`VirtualDisplay.swift:12-13`), so macOS falls back to the 1920×1080 placeholder (`docs/NOTES.md:160`), which Parsec can reach.
- `scripts/bundle-host.sh:55-78` assembles `Contents/MacOS`, `Contents/Resources`, fills `Info.plist` from a template with `__BUNDLE_ID__`/`__EXECUTABLE__` placeholders (`host-mac/Resources/Info.plist:3`), then signs. There is no `Contents/Library/LaunchAgents` today.
- T-148 fixes the first-run flag (`LoginItem.swift:42-44`, set before `register()`) and adds the pure `LoginItemPolicy.swift`; this card extends that policy.

**Design (D P-8 draft for the decision):**
- `SMAppService.agent(plistName:)` with a plist embedded at `Contents/Library/LaunchAgents/<bundle id>.agent.plist`: `Label` (required by launchd), `BundleProgram` → `Contents/MacOS/<executable>`, `RunAtLoad` true, `KeepAlive {SuccessfulExit: false}`, `ThrottleInterval` ≥ 10 s, `ProcessType Interactive`, `AssociatedBundleIdentifiers` = the app's bundle ID.
- The agent **replaces** the `mainApp` login item: registering both would launch two hosts at login. The policy must migrate (unregister `mainApp` when the agent is registered) and the menu "start at login" toggle must manage the agent.
- TCC grants (Screen Recording, Accessibility) are keyed to the signed bundle; the agent launches the same signed binary, so they should persist. Verify on the device.
- The plist source is a template in `host-mac/Resources/LaunchAgent.plist` with the same placeholders as `Info.plist`; `bundle-host.sh` fills it, `plutil -lint`s it and copies it before signing.

**Serialize with** T-148 (`LoginItem.swift`, `LoginItemPolicy.swift`; same files). T-148 must be merged first.

**Risks:** a crash loop (bounded by `ThrottleInterval`; log the relaunch so loops show up in the soak); user approval in System Settings › Login Items may be needed again after the switch from `mainApp` to the agent; an unbundled `swift run` binary must never register anything.

Wire: none.

## Kapsam dışı

- The recovery runbook itself (T-147); login-item first-run retry (T-148).
- A fallback when `CGVirtualDisplay` is unavailable (D P-9, not carded).
- Restarting after a clean Quit, logout or reboot handling beyond `RunAtLoad`.

## Kabul kriterleri

- [ ] [device] **Failure scenario first (M06 is R-tagged):** on the current build, `kill -SEGV <host pid>` or `kill -9 <host pid>` is performed and the outcome recorded in NOTES before any code (host stays down; what the tablet shows; time until a manual relaunch). The T-147 scenario 3 entry (`kill -9`) counts.
- [ ] [XCTest] **Committed red before the fix:** a test reads the `LaunchAgent.plist` template (located via `#filePath`, like `FixtureSupport.swift`), substitutes the placeholders and asserts `Label` (non-empty, the bundle ID based label launchd requires), `KeepAlive.SuccessfulExit == false`, `ThrottleInterval >= 10`, `RunAtLoad == true` and a `BundleProgram` under `Contents/MacOS/`. It fails at HEAD because the file does not exist.
- [ ] [XCTest] `LoginItemPolicy`: agent registration unregisters `mainApp` (never both); toggle off unregisters the agent and stays off across launches; not bundled → nothing registered or persisted; a failed registration is retried as in T-148.
- [ ] `scripts/bundle-host.sh` embeds the filled plist under `Contents/Library/LaunchAgents/`, lints it, and the bundle still passes `codesign --verify --strict`.
- [ ] [device] `kill -SEGV` → the host is back within ~10 s and the tablet reconnects without user action; `kill -9` behaves the same.
- [ ] [device] Quit from the menu does not relaunch; `SIGTERM` does not relaunch.
- [ ] [device] `open -a MateBridge` while the agent-launched host runs activates it and does not start a second host (a second host would take the fallback ports; there is no single-instance guard today).
- [ ] [device] Screen Recording and Accessibility grants persist after the switch and after a crash relaunch (video and input work without re-granting).
- [ ] [device] A forced crash loop (crash at launch via a debug env, if added, or repeated kills) is throttled to at most one launch per `ThrottleInterval`.
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
