# client-android — agent rules

Tablet side: discovery, connection, video decode and render, input capture (pen, keyboard, trackpad, touch).

## Target device

Huawei MatePad Pro 12.2 (2025), HarmonyOS 4.3 with the Android app runtime, 2800×1840 tandem OLED at 144 Hz, and M-Pencil (3rd gen). **There are no Google Play Services.** Never depend on GMS or Firebase.

## Stack

- Kotlin, Gradle Kotlin DSL, version catalog (`gradle/libs.versions.toml`).
- `minSdk 29`, target/compile at the latest stable SDK installed by Android Studio.
- **Android Views, not Compose.** The UI is tiny and the display is a `SurfaceView`, so fewer dependencies is better.
- Allowed libraries: AndroidX core/appcompat, kotlinx-coroutines. Anything else needs a decision record.
- Native code (decision 0012): `app/src/main/cpp/` (CMake), only the thin AAudio output wrapper; audio logic stays in Kotlin. Requires NDK `30.0.16248370` and CMake `4.1.2` (`sdkmanager "ndk;30.0.16248370" "cmake;4.1.2"`), pinned in `app/build.gradle.kts`; `./scripts/check.sh` builds it. ABI: `arm64-v8a` only. No Oboe or other native libraries.
- Package: `dev.matebridge.client`. Probes use `dev.matebridge.probe.<name>`.

## Commands

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
cd client-android && ./gradlew assembleDebug testDebugUnitTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb logcat -s 'MB:*'                      # our log tags start with MB
adb exec-out screencap -p > /tmp/tab.png  # screenshot for verification
```

## Rules

- Pure logic goes in plain Kotlin classes with JVM unit tests: the protocol codec (tested against `protocol/fixtures/`), key maps, coordinate transforms, pen sample batching.
- Pen: read `getHistoricalX/Y/Pressure/AxisValue` for every batched sample, and never drop intermediate points. Tilt comes from `AXIS_TILT` plus `AXIS_ORIENTATION`.
- Keyboard: send **scan codes / physical keys**, never characters (decision 0003).
- Trackpad: use `requestPointerCapture()` for relative motion. Release capture and all held input in `onPause`/`onWindowFocusChanged(false)`.
- Keep the screen on while streaming, run fullscreen and immersive, and lock to landscape.
- Decoder: MediaCodec in low-latency mode where supported. Render the newest frame and drop late ones.
