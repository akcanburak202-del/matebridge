# MateBridge

Turn a **Huawei MatePad Pro** into a high-quality LAN display and input terminal for a **Mac**: native-resolution virtual display, pressure- and tilt-sensitive **M-Pencil** for design and drawing, plus the tablet's keyboard and trackpad.

> Status: **Phase 0: platform probes.** Nothing usable yet.

Huawei MatePad Pro'yu Mac için ev ağında çalışan yüksek kaliteli bir ekran ve girdi terminaline dönüştürür: tablet çözünürlüğünde sanal ekran, basınç ve eğim hassasiyetli M-Pencil, klavye ve trackpad.

## Why

No existing tool covers Android pen pressure → macOS together with a sharp native-resolution display and a physical keyboard/trackpad. Decision [0001](docs/decisions/0001-custom-app-lan-first.md) explains why.

## Layout

```text
host-mac/          Swift package: virtual display, capture, encode, input injection, menu bar app
client-android/    Kotlin app for the tablet: decode/render, pen/keyboard/trackpad capture
protocol/fixtures/ golden byte vectors shared by both sides
probes/            phase-0 experiments
backlog/           task cards (the unit of work for agents) + BOARD.md
docs/              PLAN, WORKFLOW, PROTOCOL, LOGGING, NOTES (findings), decisions/
scripts/           check.sh (build+test all), board.sh, codex-review.sh
AGENTS.md          rules for every coding agent (CLAUDE.md imports it)
```

## Develop

```bash
./scripts/check.sh      # build + test everything that exists
./scripts/board.sh      # regenerate backlog/BOARD.md
```

Requirements: macOS 15+ with Xcode, and Android Studio (for its JDK and SDK). The Android client also needs the NDK and CMake for its AAudio output (decision 0012): `sdkmanager "ndk;30.0.16248370" "cmake;4.1.2"` (the versions pinned in `client-android/app/build.gradle.kts`). The target hardware is a Mac mini M6 on macOS 27 and a MatePad Pro 12.2 (2025) on HarmonyOS 4.3.

## License

Apache-2.0. Parts are adapted from [LukeLogix/android-display](https://github.com/LukeLogix/android-display) (Apache-2.0), with attribution in the source.
