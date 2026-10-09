# MateBridge

Turn a **Huawei MatePad Pro** into a high-quality LAN display and input terminal for a **Mac**: native-resolution virtual display, pressure- and tilt-sensitive **M-Pencil** for design and drawing, plus the tablet's keyboard and trackpad.

> Status: **in daily use** on the target hardware (Mac mini M6 / macOS 27, MatePad Pro 12.2 (2025) / HarmonyOS 4.3). The tablet is the Mac's only screen. Work now is reliability, latency and simplification (`docs/PLAN.md`, `backlog/BOARD.md`).

Huawei MatePad Pro'yu Mac için ev ağında çalışan yüksek kaliteli bir ekran ve girdi terminaline dönüştürür: tablet çözünürlüğünde sanal ekran, basınç ve eğim hassasiyetli M-Pencil, klavye ve trackpad.

## Why

No existing tool covers Android pen pressure → macOS together with a sharp native-resolution display and a physical keyboard/trackpad. Decision [0001](docs/decisions/0001-custom-app-lan-first.md) explains why.

## What works

All of this runs on the real hardware; the research log is `docs/NOTES.md`, the wire format `docs/PROTOCOL.md`.

- **Display.** The Mac creates a virtual display at the tablet's native 2800×1840 (HiDPI), ScreenCaptureKit → VideoToolbox HEVC → network → MediaCodec, at 60 or 120 fps. Colour options per decision [0033](docs/decisions/0033-sharp-chroma-option.md) and [0034](docs/decisions/0034-full-chroma-packed-444.md): Normal, sharp edges, and full 4:4:4 (two packed 4:2:0 streams, Günlük 60 only). HDR10 is optional in Günlük and Oyun ([0032](docs/decisions/0032-hdr10-game-mode.md)).
- **Modes** ([0030](docs/decisions/0030-modes-daily-drawing-game.md)): **Günlük** (daily work, native resolution), **Çizim** (drawing: always 120 fps, finger taps off, gestures kept) and **Oyun** (games: lower-resolution game display per [0029](docs/decisions/0029-game-display-resolution.md), low-latency layer per [0014](docs/decisions/0014-game-mode.md)). Frame rate (60/120) is its own setting per mode. `Ctrl+Shift+7` cycles the modes, `Ctrl+Shift+6` opens the settings panel ([0013](docs/decisions/0013-settings-while-streaming.md)).
- **Pen.** M-Pencil pressure, tilt, hover, pen double-tap as brush/eraser toggle ([0006](docs/decisions/0006-phase2-input-behaviour.md)), palm rejection. The pen reports about 360 samples per second (`docs/research/2026-10-08-pen-path.md`).
- **Keyboard, trackpad, mouse, touch.** Physical keycodes, so the Mac's Turkish Q layout and shortcuts work ([0003](docs/decisions/0003-keyboard-physical-keycodes.md), [0008](docs/decisions/0008-keyboard-modifier-defaults.md)); two-finger scroll and pinch zoom ([0009](docs/decisions/0009-pinch-magnify-gesture.md)). The cursor is drawn on the tablet with a short prediction, so it follows the hand without the video delay ([0036](docs/decisions/0036-local-cursor.md)).
- **Audio and clipboard.** Mac audio to the tablet through a Core Audio tap and AAudio MMAP ([0011](docs/decisions/0011-audio-streaming.md), [0012](docs/decisions/0012-aaudio-mmap-ndk.md)); shared clipboard.
- **Tablet files.** The tablet's storage appears in the Finder over USB (a chosen folder, [0028](docs/decisions/0028-tablet-files-scope.md)); over Wi-Fi only `MateBridge/Wi-Fi` ([0035](docs/decisions/0035-wifi-tablet-files.md)).
- **Security.** First connection needs a pairing code compared on both screens and an "Allow" on the Mac ([0018](docs/decisions/0018-tablet-trust-confirmation.md)); all traffic is encrypted with a per-session key ([0010](docs/decisions/0010-session-encryption.md)). Optional "Yalnız USB" profile closes the LAN surface ([0027](docs/decisions/0027-usb-only-network-profile.md)).
- **Connection and power.** Bonjour discovery; AUTO picks USB (`adb reverse`) when a cable is plugged in and Wi-Fi otherwise, and moves between them. Sleep/wake handling and Wake-on-LAN from the tablet. The virtual display is kept 10 s after a session ends so windows do not jump. Idle dimming on the tablet ([0031](docs/decisions/0031-idle-dim-off.md)).
- **Mac app.** Menu bar app, starts at login, one instance only, log file under `~/Library/Logs/MateBridge/` (`docs/LOGGING.md`).

## Known limits

- **Wi-Fi vs USB.** The last full comparison (NOTES 2026-10-01, "Wi-Fi tavanı kalktı") measured about 40 ms on Wi-Fi against about 24 ms on USB at 60 Mbps; USB has the lowest latency. On Wi-Fi, **Oyun at 60 Mbps currently runs near the capacity of the WLAN hop to the tablet**: queueing, stalls and a few disconnects while 30 Mbps stays clean, with a healthy router (NOTES 2026-10-08 and 2026-10-09). This is the radio environment, not a code change; lower the bit rate in the settings panel for Wi-Fi games.
- **Panel refresh.** HarmonyOS holds the panel at 60 Hz when nothing touches the screen (no touch, pen, mouse or trackpad), see [0016](docs/decisions/0016-game-mode-60.md); keyboard- or gamepad-only use therefore shows 60 fps even in a 120 fps mode. A 144 Hz "Yüksek" panel setting stalls the tablet's network (T-321, open).
- **Virtual display after a session.** Kept for 10 s (T-165), then removed and the Mac falls back to its headless placeholder display; a keep-time setting is T-167 (open). A capture or encoder failure removes the display at once.
- **Decoder fault.** Input is gated on decoder health and the tablet shows a fault overlay (T-159, merged); the on-device fault-injection and surface-churn soak (T-164) and the 8 h soak plus one week of use (T-194) have not been run.
- **Colour.** 4:4:4 needs the Günlük 60 setting; every other mode is 4:2:0 (HDR10 is 4:2:0 as well).
- **Crash recovery.** The host is not restarted after a crash (T-202, open); it restarts itself only when it detects its own stall (T-325). See the runbook below.

## Choosing a mode

In **Günlük** at 120 fps the Mac's virtual display runs at 120 Hz even when the panel falls back to 60 Hz, so Mac apps keep rendering 120 fps while about 60 are shown ([0016](docs/decisions/0016-game-mode-60.md); `StreamPrefsPolicy.swift`). Switching 60↔120 recreates the display, so the app never does it on its own. Advice: for long keyboard-only work set **Kare hızı: 60** in Günlük (also the only setting with full 4:4:4); for games use **Oyun** at 60 unless a mouse or touch keeps the panel at 120 (NOTES 2026-10-03 ~00:10: with no touch, the Mac GPU ran at 90% in the 120 fps setting against 54% at 60). **Çizim** is always 120 fps.

## Last verified

| | |
|---|---|
| Date | 2026-10-09 |
| Host / APK build | `ba964b63` / `ba964b63` (read it in the Mac menu "Sürüm …" line and the tablet's settings "Sürüm" row) |
| macOS | 27.0.1 (26A434) |
| HarmonyOS | 4.3.0.145 (C432E1R1P2) |
| `./scripts/check.sh` | ALL OK |

The pair and the 5-minute smoke test live in [docs/RECOVERY.md](docs/RECOVERY.md). The smoke test has not been run for this pair yet.

## Recovery

The Mac is headless, so when the tablet shows nothing: reach the Mac with **Parsec** (the only remote path; SSH and Screen Sharing are off), relaunch MateBridge, or plug in an HDMI monitor as a last resort. "Onaylı cihazları unut" (Mac menu) and "Bu Mac'i unut" (tablet) reset pairing; "USB modu" in the Mac menu keeps the adb tunnels. Scenarios, first actions and rehearsal status: [docs/RECOVERY.md](docs/RECOVERY.md).

## Layout

```text
host-mac/          Swift package: virtual display, capture, encode, input injection, menu bar app
client-android/    Kotlin app for the tablet: decode/render, pen/keyboard/trackpad capture, settings
protocol/fixtures/ golden byte vectors shared by both sides
probes/            experiments (pen sink, AAudio, HDR, 4:4:4, cursor, decoder concurrency, USB tether, ...)
tools/             measurement and test kits: measure/ (device smoke inputs), soak/, pacing/, chroma-test/, dav-repro/
backlog/           task cards (the unit of work for agents) + BOARD.md
docs/              PLAN, WORKFLOW, PROTOCOL, LOGGING, KNOBS, RECOVERY, NOTES (findings), decisions/, research/, reviews/
scripts/           check.sh (build+test all), board.sh, codex-review.sh, bundle-host.sh (signed Mac .app),
                   install-apk.sh (tablet install), usb-mode.sh (manual adb reverse), device-smoke.sh (read-only device report)
.github/workflows/ check.yml: CI merge gate (decision 0022)
AGENTS.md          rules for every coding agent (CLAUDE.md imports it)
```

## Develop

```bash
./scripts/check.sh        # build + test everything that exists
./scripts/board.sh        # regenerate backlog/BOARD.md
./scripts/bundle-host.sh  # signed release MateBridge.app in build/ (keeps the Screen Recording / Accessibility grants)
./scripts/install-apk.sh  # install the daily (non-debuggable) APK on the tablet; --debug for diagnostics
```

Requirements: macOS 15+ with Xcode, and Android Studio (for its JDK and SDK). The Android client (minSdk 31, decision [0037](docs/decisions/0037-min-sdk-and-daily-build.md)) also needs the NDK and CMake for its AAudio output (decision 0012): `sdkmanager "ndk;30.0.16248370" "cmake;4.1.2"` (the versions pinned in `client-android/app/build.gradle.kts`). The target hardware is a Mac mini M6 on macOS 27 and a MatePad Pro 12.2 (2025) on HarmonyOS 4.3.

## License

Apache-2.0. Parts are adapted from [LukeLogix/android-display](https://github.com/LukeLogix/android-display) (Apache-2.0), with attribution in the source.
