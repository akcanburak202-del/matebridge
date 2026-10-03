---
id: T-148
title: Retry login-item registration after a failure
status: todo
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

- [ ] [XCTest] First commit: `LoginItemPolicyTests` reproduces today's bug (flag set before registration; after a failed first-run registration the next launch does not retry) and **fails** against the unchanged extracted policy. The commit is recorded in Handoff.
- [ ] [XCTest] After the fix: first run + success → done, flag set; first run + failure → flag not set, next launch retries, problem shown; user toggled off → flag set, never auto-registered again; user toggled on after a failure → flag set; not bundled → nothing persisted.
- [ ] [device] With the login item removed in System Settings → General → Login Items and the flag reset (`defaults delete dev.matebridge.host loginItemFirstRunDone`), the next launch of the bundled app registers it (`ev=login_item enabled=true`), and after logout/login the host starts.
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
