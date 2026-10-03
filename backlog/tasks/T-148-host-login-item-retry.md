---
id: T-148
title: Retry login-item registration after a failure
status: done
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeApp/LoginItem.swift
  - host-mac/Sources/MateBridgeCore/Session/LoginItemPolicy.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/LoginItemPolicyTests.swift
  - backlog/tasks/T-148-host-login-item-retry.md
---

## Amaç

On a headless Mac the login item is what brings MateBridge back after a reboot or logout. Today one failed registration on the first launch marks the first run as done, so the app never retries and silently stops starting at login. After this card a failed registration is retried on the next launch and stays visible in the menu until it succeeds, while a user who turned the login item off is never overridden.

Source: external architecture review 2026-10-03 (M06); verification: docs/reviews/2026-10-03/verify-D-display.md (P-6, M06 "first-run flag").

## Bağlam

- **Evidence (HEAD a30c769), `host-mac/Sources/MateBridgeApp/LoginItem.swift`:**
  - `registerOnFirstRun()` (:40-45) writes `loginItemFirstRunDone = true` (:43) **before** calling `set(true)` (:44).
  - On a failed `SMAppService.mainApp.register()`, `set` only stores the in-memory `problem` and logs `login_item_failed` (:60-64). On the next launch the guard at :42 returns early: no retry.
  - `refresh()` (:30-36) only re-shows the "requires approval" hint, not the earlier failure. After the first launch the menu shows just an unchecked toggle.
  - The not-bundled case (`swift run`) also sets the flag (:43 runs before `set` checks `isBundled` at :52). An unbundled binary probably uses a different `UserDefaults` domain than `dev.matebridge.host`, so it likely does not poison the `.app` (not verified).
  - `LoginItemStatus` already lives in Core (`host-mac/Sources/MateBridgeCore/Usb/BoundedCapture.swift:54`), so a pure policy can use it.
- **R-tagged finding (M06): failing test first.** The first commit extracts today's decision **unchanged** into `LoginItemPolicy` (pure: inputs = flag, bundled, current status, register outcome, explicit user toggle; outputs = whether to register, whether to set the flag, problem text) and adds `LoginItemPolicyTests` for the desired behaviour. That commit is red. The fix commit turns it green.
- **Plan hints:**
  - Set the flag only after a successful registration, or when the user toggles explicitly (the user's choice then wins forever).
  - A failed first-run registration leaves the flag unset, so the next launch retries and the menu shows `problem` again (`loginProblemLine`, `main.swift:80-82`, already exists; no `main.swift` change should be needed).
  - Not bundled: persist nothing.
  - Keep `login_item` / `login_item_failed` log events as they are (fields `enabled=`, `code=`, `reason=`).
- **Out of reach here:** crash restart via a LaunchAgent (gated T-202, needs a decision).
- No wire change; `docs/PROTOCOL.md` is not affected.

## Kapsam dışı

- KeepAlive / crash supervisor (T-202), any menu redesign, login-item behaviour for the `swift run` binary beyond "persist nothing".

## Kabul kriterleri

- [x] [XCTest] First commit: `LoginItemPolicyTests` reproduces today's bug (flag set before registration; after a failed first-run registration the next launch does not retry) and **fails** against the unchanged extracted policy. The commit is recorded in Handoff.
- [x] [XCTest] After the fix: first run + success → done, flag set; first run + failure → flag not set, next launch retries, problem shown; user toggled off → flag set, never auto-registered again; user toggled on after a failure → flag set; not bundled → nothing persisted.
- [ ] [device] With the login item removed in System Settings → General → Login Items and the flag reset (`defaults delete dev.matebridge.host loginItemFirstRunDone`), the next launch of the bundled app registers it (`ev=login_item enabled=true`), and after logout/login the host starts.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. **Core policy** `MateBridgeCore/Session/LoginItemPolicy.swift` (pure enum): `Trigger` (`launch`, `userToggle`), `Action` (`none`, `register`, `unregister`), `Outcome` (`succeeded`, `failed(reason:)`, `notBundled`).
   - `action(for:firstRunDone:status:)` — which SMAppService call to make.
   - `marksDone(trigger:action:outcome:)` — whether `loginItemFirstRunDone` is written after the attempt.
   - `problem(after:)` — menu text (existing Turkish strings moved as-is).
2. **Red commit:** the policy reproduces today's decision unchanged (launch always marks done, a toggle never does); `LoginItem.swift` calls it with identical observable behaviour (the write and the attempt are synchronous in one call). `LoginItemPolicyTests` describe the desired behaviour and fail (first-run failure marks done / no retry on next launch; toggles do not mark done; not bundled persists).
3. **Fix commit:** launch marks done only on success (or when the status is already requested); `userToggle` + `unregister` always marks done (the user's off wins, even if unregister throws); `userToggle` + `register` marks done only on success (a failed toggle-on is retried on the next launch, which is what the user asked for); `notBundled` never persists. Log events `login_item` / `login_item_failed` and their fields stay unchanged.
4. Files: only the card's `files:` list; no `main.swift` change (`loginProblemLine` already shows `problem`).
5. Risk: a `swift run` binary now shows the "only with MateBridge.app" line and logs `login_item_failed reason=not_bundled` on every launch (before: only the first). Accepted: dev-only, and it is the truth.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:** fix `2010e4c` (on top of red `ce36d1e`, plan `6c8c7d4`), branch `task/T-148-host-login-item-retry`.
  - **Red commit `ce36d1e`:** `LoginItemPolicy` reproduces today's decision unchanged (launch always marks done, a toggle never does); `swift test --filter LoginItemPolicyTests` → 6 of 9 tests fail (14 issues), among them `failedFirstRunIsRetriedOnTheNextLaunch` (flag set after a failed registration, second launch makes no `register` call). Fix `2010e4c` → 9/9 green.
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Session/LoginItemPolicy.swift` (new), `host-mac/Tests/MateBridgeCoreTests/Session/LoginItemPolicyTests.swift` (new), `host-mac/Sources/MateBridgeApp/LoginItem.swift`, this card. `main.swift` unchanged.
- **Varsayımlar:**
  - Launch with the flag unset but the item already `enabled`/`requiresApproval` (e.g. enabled in System Settings) → no `register` call, flag written (as before).
  - Toggle-off writes the flag even if `unregister()` throws (the user's "off" wins). Toggle-on writes it only on success, so a failed toggle-on is retried at the next launch (what the user asked for).
  - Not bundled (`swift run`): nothing is persisted, so every unbundled launch now logs `login_item_failed reason=not_bundled` and shows the "yalnız MateBridge.app" line (before: only on the first run of that defaults domain). Dev-only.
  - Log events and fields unchanged (`login_item enabled=`, `login_item_failed enabled= code=` / `reason=not_bundled`); the error text goes only to the menu, never to the log.
  - Write order changed: the flag is written after the attempt (both are synchronous in one call on the main actor).
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - [device] AC 3: remove the login item in System Settings → General → Login Items, `defaults delete dev.matebridge.host loginItemFirstRunDone`, launch the bundled app → `ev=login_item enabled=true` and the flag is set; after logout/login the host starts. Not run here (no GUI / no real login-item changes allowed for the agent).
  - A real `SMAppService.register()` failure was not produced; the retry path is covered only by the Core tests. Optional check: with the flag unset, a failing launch should leave `defaults read dev.matebridge.host loginItemFirstRunDone` absent and show the problem line in the menu.
  - Whether the unbundled binary really uses a different defaults domain than `dev.matebridge.host` was not checked; it no longer matters because nothing is persisted when unbundled.
- **Açık sorular:** none.
