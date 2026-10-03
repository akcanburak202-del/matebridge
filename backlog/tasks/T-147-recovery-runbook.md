---
id: T-147
title: Write and rehearse the recovery runbook and known-good version pair
status: todo
phase: 6
owner: orchestrator
depends_on: [T-145, T-146]
decisions: []
files:
  - docs/RECOVERY.md
  - README.md
  - docs/NOTES.md
  - backlog/tasks/T-147-recovery-runbook.md
---

## Amaç

The Mac mini is headless and the tablet is meant to be its only screen. When the tablet shows nothing (host crash, permission loss, reboot, macOS update) there is no written, tested way back to the Mac; Parsec use is only mentioned in NOTES. This card writes a one-page Turkish runbook, `docs/RECOVERY.md`, and the user rehearses every scenario once so the answer to "tablet boş, Mac'e nasıl ulaşırım?" is known before D4 changes what happens when the tablet goes away. It also records the last known-good version pair and a real `./scripts/check.sh` pass. The orchestrator writes the runbook; the user rehearses it on the hardware.

Source: external architecture review 2026-10-03 (M06, SE5, F5, D1, X13); verification: docs/reviews/2026-10-03/verify-D-display.md (P-7, M06, SE5, Q5).

## Bağlam

- **Facts the runbook rests on (HEAD a30c769):**
  - The rollback screen is the macOS **headless placeholder display**, 1920×1080, `v0x756e6b6e/m0x76697274` (`docs/NOTES.md:160`, 2026-09-30: "fiziksel monitör değil"). It is not a physical monitor or an HDMI dummy. `docs/PLAN.md:9` ("1920×1080 bir monitör bağlı") is stale (coverage audit K3). NOTES 2026-09-29 (l.31) records only the *intention* to keep an HDMI dummy.
  - The virtual display goes away 10–11 s of awake time after a session ends (`host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift:9`), and immediately on any capture or encoder failure (`host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:279-301`). macOS then falls back to the placeholder, which Parsec can reach.
  - Parsec is the user's existing remote path: NOTES 2026-09-29 l.31 and 2026-09-30 l.253 (approval through Parsec).
  - There is no crash supervisor or KeepAlive. The login item is `SMAppService.mainApp` and runs only at user login (`host-mac/Sources/MateBridgeApp/LoginItem.swift:58`); a first-run registration failure is never retried (fixed by T-148).
  - Screen Recording loss shows only as menu text "…then restart it" (`host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift:15`); a re-grant needs an app restart. Accessibility loss is re-read when the menu opens and has an "open System Settings" item.
  - Nobody has a recorded `./scripts/check.sh` pass at a30c769; the review's test counts are not pass results (coverage audit O3).
- **R-tagged finding (M06): failure scenario first.** Each scenario is first performed and its **actual** outcome recorded (what the tablet shows, what `host.log` / `adb logcat -s 'MB/*'` say, how long until the Mac was reachable) before any fix card is written. A need found here unlocks the gated T-202 (crash restart), which needs its own decision.
- **Questions the orchestrator asks the user first** (manifest §5 Q1): which remote path is relied on (Parsec only, or also SSH / macOS Screen Sharing)? Is FileVault on? Is auto-login on? Is an HDMI dummy actually plugged in?
- **Procedure** (one device test at a time, per CLAUDE.md; the orchestrator guides, the user performs; build IDs from T-145/T-146 recorded with every result):
  1. **Baseline:** note macOS build (`sw_vers`), HarmonyOS build (`adb shell getprop ro.build.display.id`), host SHA (`app_start` line in `host.log`), APK SHA (`app_start` line in logcat). Run `./scripts/check.sh` on the Mac at that commit and record the result.
  2. **Host quit:** Quit from the menu. Tablet expectation: connection lost, then placeholder only on the Mac. Reach the Mac via the remote path, relaunch with `open -a MateBridge` (SSH) or Finder/Spotlight (Parsec/Screen Sharing). Record time to video back.
  3. **Host crash:** `kill -9 <pid>` (simulates a crash; no clean terminate). Same recovery as 2; record whether input was released on the Mac (no stuck key or button) and what the tablet shows.
  4. **Tablet app crash:** `adb shell am force-stop dev.matebridge.client`, relaunch. Record the Mac side (display grace, input release).
  5. **Network loss → USB:** in AUTO mode, start on Wi-Fi with the cable **unplugged** (with the cable plugged and "USB modu" on, AUTO has already migrated to USB, `AutoTransport.kt:193-201`, so the scenario would test nothing). Plug the cable in, then switch Wi-Fi off on the tablet. Record whether and when the session moves to USB (migration time), then unplug and record the fallback.
  6. **Screen Recording revoked:** remove MateBridge in System Settings → Privacy → Screen & System Audio Recording (via the remote path). Record the menu text and tablet state; re-grant and restart the app.
  7. **Accessibility revoked:** same for Accessibility; record `input_gate accessibility=0`, re-grant (no restart needed per NOTES).
  8. **Reboot without FileVault / with FileVault** (as applicable): record what is reachable at the login window (Parsec / Screen Sharing / nothing), whether the host starts after login, and the steps that worked. With FileVault the preboot screen needs a local keyboard and screen; say so plainly if that is the case.
  9. **Logout and login:** record whether the login item starts the host and the tablet reconnects without action.
  10. **After a macOS update — 5-minute smoke test:** display created at 2800×1840 @60 and @120 with `mode_selected=true` in `host.log`; Krita pen pressure, tilt and hover; pinch zoom; Ctrl↔Cmd shortcuts; one sleep/wake. Run it now once to have a baseline result, then after every macOS or HarmonyOS update.
- **Runbook shape (`docs/RECOVERY.md`, Turkish):** one section per scenario with symptom → first action → fallback; the 5-minute smoke checklist; the last known-good pair table (macOS build, HarmonyOS build, host SHA, APK SHA, date). Link it from `README.md` (one line; the full README rewrite is T-193).
- **Not covered here:** a fallback when `CGVirtualDisplay` breaks after an update (D P-9; research only, not carded, manifest §5 Q12). If the smoke test fails on display creation, record it and stop.

## Kapsam dışı

- Any code change (login-item retry is T-148, crash restart is the gated T-202).
- The README current-state rewrite and PLAN refresh (T-193).
- Soak runs (T-194).

## Kabul kriterleri

- [ ] [doc] The user's answers (remote path, FileVault, auto-login, HDMI dummy) are recorded in `docs/NOTES.md` and reflected in `docs/RECOVERY.md`.
- [ ] [device] Every scenario 2–9 was performed once and its **actual first outcome** is recorded in `docs/NOTES.md` with date, host SHA and APK SHA, before any follow-up card is written (M06 failure-first rule).
- [ ] [device] The 5-minute smoke test (step 10) has one recorded baseline result with build IDs.
- [ ] [doc] `docs/RECOVERY.md` exists, covers every scenario with steps that were actually rehearsed, and names the headless 1920×1080 placeholder (not a physical monitor) as the rollback screen.
- [ ] [doc] The last known-good pair (macOS build, HarmonyOS build, host SHA, APK SHA) is recorded in `docs/RECOVERY.md`, together with a recorded `./scripts/check.sh` pass on the Mac at that host/APK commit.
- [ ] [doc] `README.md` links `docs/RECOVERY.md`.
- [ ] [doc] Findings that need code are listed under *Açık sorular* (candidate: T-202 crash restart) instead of being fixed here.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
