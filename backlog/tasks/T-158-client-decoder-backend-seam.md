---
id: T-158
title: Put MediaCodec behind a DecoderCodec interface (no behaviour change)
status: done
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderCodec.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/FakeDecoderCodec.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/build.gradle.kts   # only testOptions (e.g. unitTests.isReturnDefaultValues), if the chosen seam needs it
  - backlog/tasks/T-158-client-decoder-backend-seam.md
---

## Amaç

`VideoRenderer` calls `MediaCodec` directly, so no JVM test can inject a create/configure failure, a hung `stop()`, or a codec that runs but never produces output. The H02 (frozen image with live input) and M03 (unbounded decoder hand-off) fixes in T-159 and T-161 each need such a test, and M03 is an R-tagged finding that must start with a deterministic failing test. This card adds a small `DecoderCodec` seam with a fake and changes no behaviour. When it is done, the as-is decoder lifecycle is documented by tests and the later fixes can be test-driven.

Source: external architecture review 2026-10-03 (M07 (seam), X3, X6); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (TESTSEAM-1, client half; additional issue 5) and docs/reviews/2026-10-03/verify-B-client-video.md (X3 correction).

## Bağlam

- **Evidence (HEAD a30c769):**
  - `MediaCodec.createDecoderByType(mime)` is called at `video/VideoRenderer.kt:294`, and `configure(format, surface, null, 0)` plus `start()` at `:305-306`. `createCodec` spans `:277-325`. The input thread uses `dequeueInputBuffer` (via `InputBufferSlot`, `:435`), `getInputBuffer` and `queueInputBuffer` (`:454-472`). The output side uses `dequeueOutputBuffer`, `releaseOutputBuffer(idx, renderNs | Boolean)` (`CodecSink`, `:497-508`), `outputFormat` and `setOnFrameRenderedListener`. Teardown is `codec.stop()` / `codec.release()` in `runCodec.finally` (`:482-489`).
  - Diagnostics also read `codec.name`, `codec.codecInfo` (low-latency feature check, `:296-302`) and `codec.inputFormat` (`:310-320`).
  - The only video JVM tests today cover `FrameQueue`/`RestartPolicy` and pacing (`app/src/test/.../video/VideoTest.kt` and friends). There is no `androidTest` tree.
- **Why a seam first:** the coverage audit (§3 p11, §4.3) asks that the M01/M02/M03 deterministic tests have their seams ready up front rather than discovered mid-task. The audit folded H TESTSEAM-1's `DecoderBackend.kt` and B P3's `DecoderCodec` into this one card; the name is `DecoderCodec`.
- **Plan hints:**
  - Keep the interface minimal: create (factory), configure, start, dequeueIn, input buffer access, queueIn, dequeueOut, releaseOut (render timestamp and boolean variants), stop, release, plus the read-only diagnostics the renderer logs (name, low-latency support, input/output format keys). Add nothing the renderer does not already call.
  - The `configure(format, surface…)` surface argument stays an opaque handle in the interface, so the fake never needs an Android `Surface`. `MediaFormat` construction may stay in the adapter if that keeps the JVM fake free of Android classes; check how existing JVM tests avoid `android.*` (the unit-test `android.jar` stubs throw).
  - The production adapter wraps `MediaCodec` 1:1. `VideoRenderer` gets a constructor parameter (or internal factory property) defaulting to the adapter, so `MainActivity` does not change.
  - The fake is scriptable: fail on create/configure/start, throw on dequeue, return "try again later" forever (silent: input accepted, no output), and block inside `stop()`/`release()`/`dequeueOutputBuffer` until a test latch opens.
  - Threads: the fake must work with the real `mb-decoder` / `mb-decoder-out` threads; tests use latches, not sleeps.
  - **Risk: `VideoRenderer` is not JVM-loadable today.** No JVM test constructs it. It imports `android.util.Log`, `android.os.SystemClock`, `android.os.Process`, `android.os.Build` and `android.view.Surface` (`VideoRenderer.kt:3-9`), and `runCodec` also builds a `MediaCodec.BufferInfo` (`:403`) and a main-looper `Handler` for the rendered listener (`:396`). In addition, `app/build.gradle.kts` does not set `unitTests.isReturnDefaultValues`, so stubbed calls such as `Log.w`/`SystemClock.elapsedRealtime()` throw in unit tests. Robolectric or a mocking library is not allowed without a decision (decision 0005 allows only JUnit/kotlin-test). So the seam must also make the lifecycle path runnable on the JVM: inject a monotonic clock and a log sink alongside `DecoderCodec`, or extract the generation lifecycle (`decodeLoop` / `decodeAttempts` / the `runCodec` skeleton) into a pure class the renderer delegates to. Choose one in *Plan* and justify it. If neither is enough, `testOptions.unitTests.isReturnDefaultValues = true` in `build.gradle.kts` is allowed (see the orchestrator note); nothing else in that file.
- **What the tests document (as-is, no fix):** give-up after 3 restarts within 10 s (`RestartPolicy.kt:4`, `VideoRenderer.kt:341-355`) calls `onGiveUp` and leaves `attached == true`; `decodeLoop` waits on `att.previous?.join()` with no timeout (`:328`); `runCodec.finally` joins the output thread for at most 500 ms, then stops and releases the codec anyway (`:484-487`). These tests are expected to change in T-159/T-161, which is fine.
- **Serialize with:** `VideoRenderer.kt` chain T-158 → T-159 → T-160 → T-161 → T-168 → T-183 → T-184. This card is the head; T-159 depends on it.
- No wire change; `docs/PROTOCOL.md` is not affected.

Orchestrator note (2026-10-03): `build.gradle.kts` was added to `files:` so the implementer may set `testOptions.unitTests.isReturnDefaultValues = true` if needed. Prefer the cleaner option if it fits: an injected clock/log sink, or moving the lifecycle logic into a pure class. Decision 0005 still rules out Robolectric and mocking libraries.

## Kapsam dışı

- Any behaviour change: health state, give-up handling, join timeouts, restart backoff (T-159, T-161).
- The debug `--es decoder_fault` extra (T-159).
- GL presenter (`GlPresenter.kt`), pacers, `FrameQueue`.
- Host-side encoder seam (T-162).

## Kabul kriterleri

- [x] [JVM] `DecoderCodec` interface plus a `MediaCodec` adapter exist; `VideoRenderer` no longer references `MediaCodec` instance methods except through the adapter (a `grep` in Handoff shows it).
- [x] [JVM] With `FakeDecoderCodec`, a test drives `runCodec`/`decodeAttempts` through 4 failing creates and observes today's behaviour: 3 restarts, then `ev=give_up` and exactly one `onGiveUp` call, `attached` still true.
- [x] [JVM] With the fake, a test documents today's hand-off ordering: a new attachment's decoder thread does not start a codec until the previous decoder thread exits (`previous.join` with no timeout). The test uses latches and finishes; it must not hang the suite (release the latch in `finally`).
- [x] [JVM] A fake in "silent" mode (input accepted, no output ever) runs without `decode_error`, which documents the T-028 no-output case the review missed.
- [x] No behaviour change: existing video tests pass unchanged; log lines (`codec_start`, `codec_stop`, `decode_error`, `give_up`, `detach_slow`) keep their fields.
- [ ] [device] Smoke on the tablet: connect over USB, 10 mode changes (Netlik ↔ Akıcı ↔ Oyun 60), background/foreground twice. Image after each change, no `decode_error`, `codec_start` line unchanged (same `name=`, `low_latency=`).
- [x] `./scripts/check.sh` geçiyor.

## Plan

Chosen seam: **`DecoderCodec` + an injected `DecoderEnv` (clock, log sink, thread tid/priority)**, so the real
`VideoRenderer` (its own `mb-decoder` / `mb-decoder-out` threads, `decodeLoop` / `decodeAttempts` / `runCodec`) runs
on the JVM unchanged. Why not the alternatives: extracting the lifecycle into a pure class would move most of `runCodec`
(pacers, releaser, gauge) and is a much larger diff with more behaviour-change risk, and a new file is outside `files:`;
`isReturnDefaultValues` would make `Log` silent (the tests must observe `ev=give_up`) and `SystemClock` return 0, so it
is not needed and `build.gradle.kts` stays untouched.

1. `video/DecoderCodec.kt` (new):
   - `interface DecoderCodec`: `name`, `lowLatencySupport(mime)` (null = API < 30, i.e. today's `n/a`), `configure(format,
     surface: Any)`, `start`, `dequeueInputBuffer`, `getInputBuffer`, `queueInputBuffer`, `dequeueOutputBuffer(OutputInfo,
     timeoutUs)`, `releaseOutputBuffer(idx, renderNs)`, `releaseOutputBuffer(idx, render)`, `setOnFrameRenderedListener`,
     `inputFormat` / `outputFormat` (read-only `FormatView`: `containsKey`, `getInteger`, `getFloat`), `stop`, `release`;
     nested `Factory` (`create(mime)`), `OutputInfo` (pts, flags), and the two MediaCodec int constants the renderer uses.
   - `DecoderFormat`: pure builder (mime, size, ordered integer keys); the adapter turns it into a `MediaFormat`.
   - `MediaCodecDecoder`: the 1:1 adapter (`createDecoderByType`, `configure(format, surface, null, 0)`, the API-30
     low-latency feature check, the main-looper `Handler` for the rendered listener, one `BufferInfo` copied into
     `OutputInfo`).
   - `DecoderEnv` + `AndroidDecoderEnv`: `SystemClock.elapsedRealtime[Nanos]`, `Log.{i,w,e}`, `Process.myTid`,
     `Process.setThreadPriority(THREAD_PRIORITY_DISPLAY)`.
2. `VideoRenderer.kt`: two new trailing constructor parameters with production defaults (`MainActivity` unchanged); all
   `MediaCodec` / `Build` / `SystemClock` / `Log` / `Process` / `Handler` calls go through them; log line texts unchanged.
   `attachSurface(Surface)` delegates to `internal attachTarget(Any)` (tests pass a plain object).
3. Tests (`test/.../video/FakeDecoderCodec.kt`, `DecoderLifecycleTest.kt`): scriptable fake (fail create / configure /
   start, throw on dequeue, silent = input accepted and no output, block in stop / release / dequeueOutputBuffer on a
   latch, ordered event log); tests for give-up after 3 restarts, `previous.join` hand-off ordering, silent mode.

Risks: a hidden behaviour change in `createCodec` ordering (format keys, low-latency check before configure) — kept in
the same order; the `BufferInfo` copy adds two field writes per dequeue (negligible).

## Handoff

- **Commit:** `915354b` (implementation; plan in `42cfbdf`). Branch `task/T-158-client-decoder-backend-seam`.
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/DecoderCodec.kt` (new: `DecoderCodec`, `DecoderFormat`,
    `MediaCodecDecoder` adapter, `DecoderEnv`, `AndroidDecoderEnv`)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt`
  - `client-android/app/src/test/kotlin/dev/matebridge/client/video/FakeDecoderCodec.kt` (new: `FakeDecoderFactory`,
    `TestDecoderEnv`)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/video/DecoderLifecycleTest.kt` (new, 4 tests)
  - `build.gradle.kts` not touched (no `isReturnDefaultValues` needed). `MainActivity` unchanged.
- **grep (acceptance 1):** `grep -n "MediaCodec\|android\." VideoRenderer.kt` shows only `import android.media.MediaFormat`
  (compile-time `KEY_*` / `MIMETYPE_*` constants, inlined), `import android.view.Surface` (public `attachSurface`
  signature), the class KDoc, and the default `codecFactory = MediaCodecDecoder.FACTORY`. No `MediaCodec` instance call,
  no `SystemClock` / `Log` / `Build` / `Process` / `Handler` left in the file.
- **Tests (`DecoderLifecycleTest`, real `mb-decoder` / `mb-decoder-out` threads, monitor/latch waits only):**
  - 4 failing creates → 4 `decode_error err=IOException`, 3 `KEYFRAME_REQUEST(DECODE_ERROR)`, one `give_up`, one
    `onGiveUp`, 4 `codec_stop`, `attached == true`.
  - Hand-off: old thread blocked in `stop()` → no `create#2` for 700 ms (> `JOIN_MS` and the 500 ms out-thread join);
    after the gate opens the exact order is `create#1 configure#1 start#1 stop#1 release#1 create#2 …`. Gates are opened
    in `finally` and in `@After`.
  - Silent codec: 31 inputs accepted, output thread polls try-again-later ≥ 20 more times → no `decode_error`, no
    `give_up`, one codec.
  - `codec_start` line fields (`name= mime= size= low_latency= requested_rate= accepted priority= operating_rate=
    low_latency_fmt=`) and `codecInfo` text.
  - Ran 6× with `--rerun`, all green (~0.9 s per run). `./scripts/check.sh`: ALL OK.
- **Varsayımlar:**
  - `MediaFormat.createVideoFormat` now runs inside the adapter's `configure` (after `createDecoderByType` instead of
    before); it has no side effects. Integer keys are applied in the same order, `KEY_LOW_LATENCY` last as before.
  - The adapter keeps one `MediaCodec.BufferInfo` per codec and copies `presentationTimeUs` / `flags` into
    `DecoderCodec.OutputInfo` after each `dequeueOutputBuffer` (only the output thread calls it, as before).
  - The rendered-frame listener's main-looper `Handler` is created in the adapter, still once per codec start.
  - `DecoderCodec.INFO_TRY_AGAIN_LATER` is exposed in addition to the two constants the renderer uses, for the fake only.
  - The fake's `dequeueOutputBuffer` parks for its timeout (stands in for a real blocking dequeue); that is not a test
    sleep.
- **Test edilmeyenler / cihazda doğrulanacaklar:** nothing ran on the tablet. Orchestrator smoke (acceptance [device]):
  1. USB connect; first image appears; `adb logcat -s 'MB:*'` → `MB/decoder ev=codec_start` has the same `name=` (the
     HiSilicon HEVC decoder) and `low_latency=` value as on `main`, and `accepted priority=… operating_rate=…
     low_latency_fmt=…` unchanged.
  2. 10 mode changes (Netlik ↔ Akıcı ↔ Oyun 60): image after each, one `codec_stop` + `codec_start` pair per change, no
     `decode_error`, no `detach_slow`.
  3. Background / foreground twice: image comes back each time, no `decode_error`.
  4. Pacing unchanged: `MB/render ev=present` and `ev=stats` lines look as before (shown-time stats still populated, i.e.
     the frame-rendered listener still fires on the SurfaceView path).
- **Açık sorular:** none. Note for T-159/T-161: `FakeDecoderFactory` has no "produces output" mode yet (the frozen-image
  test will need one: return an output index + `OutputInfo` per queued input); add it there.
