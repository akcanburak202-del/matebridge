---
id: T-180
title: Run the pen and keyboard device validation matrix
status: todo
phase: 6
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/NOTES.md
  - scripts/
  - backlog/tasks/T-180-pen-keyboard-validation-matrix.md
---

## Amaç

T-025 was closed by user decision with several pen and keyboard checks left as "kullanım sırasında izlenecek". Tilt direction was only checked qualitatively, corner accuracy and real light dots were never tested, and Wi-Fi-off mid-stroke and keyboard detach mid-hold were never run. This card runs the remaining device matrix once, so pen and keyboard behaviour is documented rather than assumed. It also measures how long releases take to arrive after a disconnect. Every failure becomes its own follow-up card. User and orchestrator run it together: the user handles the pen and keyboard, and the orchestrator runs the recorders and the logs.

Source: external architecture review 2026-10-03 (PK2, PK3, PK7, X2, X9, X10, D7, IN4); verification: docs/reviews/2026-10-03/verify-G-input.md (P-PK).

## Bağlam

**Evidence at HEAD (a30c769):**
- **Tilt:** the client computes `tilt_x = sin θ · sin φ` and `tilt_y = −sin θ · cos φ` (`client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Coords.kt:50-55`). The G report cites :246-256; the actual lines are :50-55. PROTOCOL §4 (`docs/PROTOCOL.md:269`) calls this "geçicidir ve cihazda kalibre edilecektir". Only a qualitative Krita check exists (T-025: "Pencil-5 Tilted" changes; xTilt/yTilt ≈ 12–29). The app allows **both** landscape rotations (`sensorLandscape`, `client-android/app/src/main/AndroidManifest.xml:22`), so the `AXIS_ORIENTATION` frame must also be checked after a 180° flip. Tilt in contact updates only 1–5 times per stroke (platform property, NOTES l.46).
- **Light dots:** the short-contact filter drops only a contact that ends while still held, which is a single sample with no history under 10 ms (decision 0007, `PenTracker.kt`). Drops are counted as `bounce_dropped` (client input stats line, `input/Model.kt:203`). Only synthetic `adb input stylus tap` dots were tested.
- **Pressure** is linear end to end; there is no curve anywhere.
- **Releases:**
  - Code paths exist: client `releaseAll` on focus, background or device removal (`InputCapture.kt:249`); host release order and owed releases (`OwedRelease.swift`); `input_release`/`owed` lines (`host-mac/Sources/MateBridgeHost/Input/InputController.swift:225-238`, `:295-303`).
  - Already covered on device (T-025, NOTES l.182-193): cable pull mid-stroke, Home, notification panel, force-stop.
  - Never run: Wi-Fi off mid-stroke, Shift/Ctrl+drag during USB pull or background, Glide keyboard detach while a key is held (`InputCapture.onDeviceRemoved`, T-033), dead keys.
  - The trigger→posted-release "close time" (X2) is not logged anywhere.
- **Inject test:** the T-023 `--inject-test` tilt and eraser fixture steps (1c and 3) were never run (`backlog/tasks/T-025-*.md:55`). Run them here (`host-mac/Sources/MateBridgeApp/InjectTestCommand.swift`).
- **Already done, do not repeat** (NOTES 2026-09-30 l.245): Turkish characters, ISO keys, AltGr+Q, Ctrl→Cmd shortcuts, repeat, Caps Lock, no stuck key on background, lock-screen password.

**Procedure (orchestrator; the user handles pen and keyboard):**
1. Record the host and APK commit SHAs (`ev=app_start` from T-145/T-146, or the `git rev-parse --short HEAD` of each build), plus macOS and HarmonyOS builds. Use USB unless a row says Wi-Fi.
2. Recorders:
   - a scratch Mac `CGEventTap` listener (listen-only, mouse/tablet only: type, time, location, pressure, tilt) and a scratch tablet `getevent` capture, as in T-025;
   - if a recorder is worth keeping, version it under `scripts/` with a usage header. Otherwise keep it scratch and write its recipe in NOTES.
   - Never record key characters.
3. **Tilt:** Krita Tablet Tester. Lean the pen left, right, toward the user and away from the user, in landscape and then in the 180°-flipped landscape. Record the sign of xTilt/yTilt for each lean; it must match the physical lean (PROTOCOL §4 definition, `:262-263`, `:269`). Then run `--inject-test` steps 1c and 3.
4. **Accuracy:** place targets at the 4 corners and the centre of the Mac virtual display. Do this in a full-size mode (Netlik 60) and in a scaled mode where letterbox bands appear (Performans or Oyun 120). Touch each target with the pen and record the Mac event location vs the target. The error must be < 1 pt. Touches in the letterbox band must not produce events outside the display.
5. **Pressure:** a slow light→hard ramp gives a monotonic pressure trace. A very light first touch draws in Krita.
6. **Dots:** 20 deliberate real dots in Krita. Visible dots + `bounce_dropped` must equal 20 contacts in `getevent`. Any lost real dot is a failure.
7. **Hover, eraser, double-tap:** hover cursor shown; double-tap switches to the eraser and back in Krita (fixed by T-031, user-verified 2026-09-30; re-check only).
8. **Release matrix**, each with the host `input_release` and `owed` lines captured:
   - Wi-Fi off mid-stroke (session on Wi-Fi);
   - Shift+drag and Ctrl+drag during a USB cable pull;
   - Shift+drag and Ctrl+drag while the app is backgrounded (Home).
   Expected: no ghost down or held modifier on the Mac afterwards. Close time = trigger (tablet logcat/getevent time) → release posted (Mac listener time). Both sides are on NTP wall clock, so state the method and its ± error.
9. **Keyboard:** detach the Glide keyboard (Bluetooth off) while holding a letter key and while holding Shift: no stuck key or repeat on the Mac. Dead keys in the Turkish-QWERTY-PC layout (a dead accent key followed by a vowel) produce the composed character.
10. Write a dated NOTES table with one row per check (pass/fail/not run) and the build IDs.

**If the tilt sign is wrong:** the orchestrator changes the PROTOCOL §4 tilt formula (`docs/PROTOCOL.md:269`) and any golden vector that depends on it, and creates follow-up host and client cards. That is a **wire** change and is not done inside this card. Other failures each become a separate fix card.

Wire: none (unless the tilt sign is wrong; see above).

## Kapsam dışı

- Fixes of any kind (each failure becomes its own card).
- Palm-before-pen measurement (T-181), Wi-Fi pen rhythm (T-179).
- Apps other than Krita and the Tablet Tester, beyond noting obvious problems.

## Kabul kriterleri

- [ ] [device] Tilt: 4 directions × 2 landscape rotations; the Krita Tablet Tester sign matches the physical lean in every cell, or the mismatching cells are recorded. `--inject-test` steps 1c and 3 are run and their results recorded.
- [ ] [device] Corners + centre, full-size and letterboxed: error < 1 pt per point, or the measured error is recorded as a failure.
- [ ] [device] Pressure ramp is monotonic, and a light first touch draws.
- [ ] [device] 20 real dots: none lost (visible + `bounce_dropped` = contacts in `getevent`).
- [ ] [device] Hover, eraser (double-tap) and double-tap behaviour recorded.
- [ ] [device] Wi-Fi off mid-stroke; Shift+drag and Ctrl+drag during a USB pull and during background: no ghost down or held modifier. `input_release`/`owed` lines and the close time (with method and error) are recorded.
- [ ] [device] Glide keyboard detach while holding a key (letter and Shift): no stuck key or repeat. Dead keys work.
- [ ] [doc] docs/NOTES.md has a dated entry with a pass/fail/not-run row per check, the build IDs and no key characters. Each failure has a one-line follow-up card proposal for the orchestrator.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
