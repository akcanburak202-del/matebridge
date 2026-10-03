# Verification H: tests/CI, docs and build identity, experiment sprawl, copy costs, resource leaks, overall verdict

Verifier scope: S1, S2, S3, P1, P2, P3, P4, M07 (CI part, "keep" list, acceptance criteria), L01, L02, L03 (client side), W4 (rows "Android codec", "Ses/Audio" and the closing verdict paragraph), SE6, SE8, PF4 (client half), X11, D8, D9 (README, build ID and settings reset parts), D10, F1, F3, F4, F5, A2 (fixtures, state machines and fuzz bullet).
Repo HEAD: a30c769 (matches the review).

**Commands I actually ran:**
- `python3 protocol/fixtures/gen.py --check` exited 0.
- Fixture count: `ls protocol/fixtures/*.hex | wc -l` = 48. Every stem appears in `docs/PROTOCOL.md` as a whole word. The full `.hex` filename is referenced for only 3 of them (`hello`, `hello_ack`, `hello_ack_pending`, at :681). `check.sh` greps stems, so stems are the contract.
- Test tree counts: `find host-mac/Tests -name '*.swift'` = 68, and `find client-android/app/src/test -name '*.kt'` = 98. These include support files. Test case counts are 682 `@Test` plus 334 `func test…` (Swift) and 1210 `@Test` (Kotlin).
- `.github/` does not exist. No `androidTest` directory exists anywhere.
- `wc -l`: MainActivity.kt = 2124, SessionServer.swift = 1805.

**Disclosure:** while checking for a help flag, I ran `python3 protocol/fixtures/gen.py --help`. `gen.py` treats any invocation without `--check` as "regenerate", so it rewrote the 48 fixture files. The output was byte-identical: `git status --porcelain` was empty afterwards. No net change happened, but it was a write. See Additional issue 1.

---

## Verdicts

### S1 — "Hardware-tested personal beta"; don't rewrite; prioritise trust, video health, display continuity, real e2e measurement, then Wi-Fi
- Verdict: CONFIRMED (as an assessment)
- Evidence:
  - The hardware log is extensive: `docs/NOTES.md` has 1120 lines of dated device runs, and 141 of 144 cards are done (`backlog/BOARD.md`).
  - Only one sustained-stability run exists: the 30-minute run at NOTES.md:150-155 (2026-09-30, before audio, files, sleep/WoL and game modes landed).
  - The PLAN's own Phase 4 exit criterion ("one week of daily work with no 'I had to restart'", PLAN.md:173) is not evidenced anywhere. "Beta" is therefore the project's own status too.
- Corrections:
  - The ordering itself is opinion.
  - It matches what the code lacks: there is no decoder-health input gate (`MainActivity.kt:1154` `onGiveUp` only logs), and display life is tied to the session (H04, other verifier).
- Severity opinion: agree.

### S2 — 5 headline results = H01..H05; 0 Critical / 5 High / 7 Medium / 3 Low
- Verdict: CONFIRMED (internally consistent)
- Evidence: the report's own tables list H01–H05, M01–M07 and L01–L03. The counts add up.
- Corrections: none in my area. Verification of the individual H/M items belongs to other verifiers.
- Severity opinion: the L items in my scope are rightly Low. M07 is rightly Medium (see below).

### S3 — USB is fine for a personal daily trial with a rollback path; Wi-Fi as the sole main screen needs H01–H05 plus acceptance tests
- Verdict: CONFIRMED
- Evidence:
  - USB is already the user's daily, drawing and gaming path: PLAN.md:181 ("Kullanıcı çizim ve oyun için USB kullanacağını söyledi"), and NOTES.md:1117 records transport mode "Otomatik".
  - Wi-Fi is materially worse: NOTES.md:631-639 shows Wi-Fi at ~40 ms versus 24 ms over USB, and T-127 (re-evaluating Wi-Fi with Mac Ethernet) is still `todo`.
  - A rollback path exists in practice: a physical 1920×1080 monitor (PLAN.md:9) and Parsec for unlocking (NOTES.md:478).
- Corrections:
  - "Rollback path" is not documented as a runbook anywhere in the repo.
  - The README says "Nothing usable yet" (README.md:5), so a new reader would not know a rollback is even needed. See L01.
- Severity opinion: agree.

### P1 — README still describes early Phase 0
- Verdict: CONFIRMED
- Evidence:
  - README.md:5: `> Status: **Phase 0: platform probes.** Nothing usable yet.`
  - The Layout section (README.md:17-27) omits `tools/` and the scripts `install-apk.sh`, `usb-mode.sh` and `bundle-host.sh`. It also says nothing about audio, the files/WebDAV feature, encryption, game modes or sleep/WoL.
  - `docs/PLAN.md` is stale too:
    - Hardware table: "Model/çözünürlük: **?**" (PLAN.md:10).
    - Phase 4 checklist items that are done are still unchecked (PLAN.md:167-169: sleep/wake recovery is T-128..T-134; the settings panel is decision 0013).
    - Phase 5 text cites a "~90 fps" decoder ceiling and "~13–15 ms" encode (PLAN.md:179). NOTES.md:1099-1103 and 1104 disprove both: 120 fps at full resolution, `enc_ms` p50 ~7.2 ms.
- Corrections: the review cites only README. PLAN.md is also stale, which matters because CLAUDE.md and AGENTS.md point agents at PLAN.
- Severity opinion: Low, agree.

### P2 — `gen.py --check` passes; all 48 `.hex` names are in PROTOCOL.md
- Verdict: CONFIRMED
- Evidence:
  - Exit 0. There are 48 `.hex` files, and all 48 stems are found as words in docs/PROTOCOL.md (e.g. :79, :103, :630-636).
  - `scripts/check.sh:45-50` enforces the stem reference.
  - The crypto vectors are checked separately at check.sh:39-42 (`swift protocol/fixtures/crypto_vectors.swift | diff`). That step needs macOS CryptoKit, so I could not run it here.
- Corrections: none.
- Severity opinion: n/a (positive finding).

### P3 — 68 Swift test files (host), 98 Kotlin JVM test files (client)
- Verdict: CONFIRMED
- Evidence:
  - Counts are exact. They include the support files `InputTestSupport.swift`, `CryptoTestSupport.swift`, `FixtureSupport.swift` and `TestSupport.kt`.
  - Test cases: Swift 682 `@Test` plus 334 XCTest methods; Kotlin 1210 `@Test`.
- Corrections:
  - The only Swift test target is `MateBridgeCoreTests` (host-mac/Package.swift:18). `MateBridgeHost` has no test target, so HEVCEncoder, SessionServer, StreamCoordinator, ScreenCapture and CGEventPoster lifecycle code is untested by construction.
  - On the client, `VideoRenderer` (MediaCodec), `SessionController` and `MainActivity` have no JVM tests. The pure parts that were extracted do: SessionMachineTest, FrameQueueBurstTest, the pacer tests and others.
  - This matters for the review's own M02/M03/H02 test asks. See M07.
- Severity opinion: n/a.

### P4 — No `.github/workflows`, no `androidTest`; no visible automated platform gate
- Verdict: CONFIRMED
- Evidence:
  - `.github/` and `client-android/app/src/androidTest` are both absent.
  - CI was deliberately deferred:
    - T-001 card line 20: "CI (GitHub Actions). Derlenecek kod olunca ayrı kartla eklenecek." That card was never created.
    - PLAN.md:48 lists CI as "atılan / ertelenen".
  - The only gate is the manual, local `./scripts/check.sh` on the owner's Mac (AGENTS.md "Verify before handoff"; WORKFLOW.md:28 "derleme geçer"). Nothing records that it ran for a given merge.
- Corrections:
  - A gate exists, but it is manual and unrecorded. "No visible automated gate" is accurate.
  - An on-device decoder harness exists but is never automated: `client-android/app/src/debug/.../VideoTestActivity.kt` plays a dumped `test.h265` through the real `VideoRenderer`.
- Severity opinion: covered by M07 (Medium). See below.

### M07 — Tests strong, but platform and soak evidence not reproducible (CI part, keep list, acceptance criteria)
- Verdict: PARTIALLY CORRECT
- Evidence (problem statement):
  - No CI and no instrumentation tree (P4).
  - NOTES.md:1117 confirms the latest measurement tools were in scratch (`mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`) and says "kayboldularsa NOTES'taki tariflerden yeniden yazılır". Others are also scratch-only: `brab.py`, `netsrv.py`, `sparse.py`, `blinker` and `tick` (NOTES.md:398, 541, 603).
- Evidence ("keep" list): every named area has tests at HEAD.
  - Input ownership: `PointerOwnershipTests.swift`.
  - Owed release: `OwedReleaseTests.swift`.
  - Disconnect/reset: `SafetyTests.swift`, `InputHardeningTest.kt`, `InputCaptureTest.kt`.
  - Key mapping: `KeyMapTests.swift`, `KeyboardPlannerTests.swift`.
  - Fuzz: `InputFuzzTests.swift`, `KeyboardFuzzTests.swift`, `InputFuzzTest.kt`.
  - Malformed protocol: the `invalid_*` fixtures via `FixtureTests.swift` and `FixtureTest.kt`, plus `CodecRulesTest.kt`.
  - FrameQueue and keyframe coalescing: `KeyframeRequestCoalescerTests.swift`, `KeyframeResyncTests.swift`, `FrameQueueBurstTest.kt`.
  - Pacing traces: `PaceTraceTest.kt`, `SparseFrameNoHoldTest.kt`, `ConstantPlayoutPacerTest.kt`.
  - Audio jitter, drift and refill: `AudioJitterBufferTest.kt`, `DriftControllerTest.kt`, `UnderrunRefillTest.kt`, `PlayoutSimulationTest.kt`.
- Corrections:
  1. Replay material is partly versioned already. `tools/pacing/` holds `sim.py`, `gaps.py` and `trace7_120hz_excerpt.csv` (3000 frames, timing columns only, no content). JVM tests replay it: `SparseFrameNoHoldTest.traceReplayOldVersusNew`, and `ConstantPlayoutPacerTest` per tools/pacing/README.md:8-14. So "replay material and analysis scripts versioned in repo" is half done. Monitoring and soak scripts are what is missing.
  2. The new logic tests the review asks for are not "just add tests":
     - The M02 encoder submit/stop test needs a seam. HEVCEncoder lives in `MateBridgeHost`, which has no test target.
     - The M03/H02 decoder tests need a codec interface. `VideoRenderer` calls `MediaCodec` directly (VideoRenderer.kt:276-305, 454-472).
     - Both need a small extraction into Core, or a fake-codec interface, first.
  3. CI feasibility is better than it looks:
     - The host tests are pure Core. Imports are Foundation, CryptoKit, Darwin, Dispatch, Synchronization and dnssd only. Keychain is faked (`KeychainAsyncTests`). Bonjour tests self-skip when mDNSResponder is unreachable (ControlSocketTests.swift:694, WakeOnLanTxtTests.swift:130).
     - `CGVirtualDisplay` is resolved at runtime via `NSClassFromString` (VirtualDisplay.swift:47-56). The host therefore compiles on a hosted macOS runner without private headers. SCK, VT and CGVirtualDisplay are never executed in tests, so the hosted-runner limitation does not matter for `swift test`.
     - Android needs AGP 9.4.1, Gradle 9.8.0, compileSdk 37, NDK 30.0.16248370 and CMake 4.1.2 (build.gradle.kts:7-9, 35; client-android/build.gradle.kts:2). On a runner that means downloads from `services.gradle.org`, `dl.google.com`/`maven.google.com` and the sdkmanager channel. GitHub-hosted runners can reach these; this sandbox cannot.
  4. `scripts/check.sh` is not CI-portable as-is:
     - It hard-codes macOS JDK/SDK discovery (check.sh:24-26).
     - It builds every `probes/*` project (2 extra Gradle and 2 extra SwiftPM projects).
     - On a Linux runner that has Swift preinstalled (GitHub Ubuntu images ship Swift), it would try `swift build` on `host-mac` (AppKit) and `swift protocol/fixtures/crypto_vectors.swift` (CryptoKit) and fail.
     - A CI needs component selection: Additional issue 2, work item CI-1.
- Severity opinion: Medium, agree.
  - The CI part is cheap and high value in an agent-driven repo where merges are gated only by an unrecorded local run.
  - Soak evidence is the bigger gap. It is the PLAN's own Phase 4 exit (D10).

### L01 — Docs and build identity don't track the real system
- Verdict: CONFIRMED
- Evidence:
  - README (P1). `client-android/app/build.gradle.kts:15-16`: `versionCode = 1`, `versionName = "0.1"`.
  - No `BuildConfig`, git SHA or build-date field exists anywhere in `client-android/app/src/main`. `grep BuildConfig` finds nothing, and there is no `buildFeatures { buildConfig = true }`.
  - Host: `host-mac/Resources/Info.plist:22-25` has `CFBundleShortVersionString` 0.1. `CFBundleVersion` is a build timestamp injected by `scripts/bundle-host.sh:64-67` (`date +%Y%m%d%H%M%S`).
  - No host code reads `CFBundleVersion` or logs it. `grep CFBundleVersion|infoDictionary` in Sources finds nothing.
  - The host's first log line is `listening` (SessionServer.swift:1068-1071). It carries the transport knob values, not the version or commit.
  - HELLO carries `protocol_version` only, not an app version (PROTOCOL.md §2).
- Corrections:
  - The host does have a build date, but only inside the bundle's Info.plist. It is not logged and has no commit.
  - The review missed PLAN.md staleness (see P1).
- Severity opinion: Low, agree. It becomes material once soak or acceptance results must name a commit (M07 acceptance).

### L02 — Experiment options complicate the daily product path
- Verdict: PARTIALLY CORRECT
- Evidence:
  - MainActivity.kt is 2124 lines; SessionServer.swift is 1805.
  - The client reads 33 distinct launch-extra keys, 32 of them in `MainActivity.onCreate`/helpers (MainActivity.kt:295-495) plus `AudioPlayout.kt:94,114`.
  - The host reads 25 `MATEBRIDGE_*` runtime environment variables and has 4 CLI bench/test modes (`main.swift:6-9`).
  - There are three pacer classes (`FramePacer`, `AdaptivePacer`, `ConstantPlayoutPacer`; VideoRenderer.kt:368-378), plus a GL presentation path, a PerformanceHint hook and a reflection call into a hidden Huawei API (`RefreshVote.kt:149-152`).
  - Full inventory below.
- Corrections:
  1. **None of the knobs reach the daily settings UI.** `SettingsCatalog.kt:136-220` exposes only these, each verified on device:
     - transport;
     - stream mode: Netlik 60, Akıcı 120, Performans, Oyun 120, Oyun 60 (`StreamMode.kt:10-19`, decisions 0014 and 0016);
     - bitrate;
     - audio on/off and output (Düşük gecikme/Uyumlu);
     - touchpad and mouse speed, finger-touch off, pen trail and pen dot;
     - files;
     - clipboard;
     - stats overlay.

     The "few verified profiles" the review recommends (D8/F3) already exist.
  2. "Multiple pacers" overstates the daily-path cost.
     - Non-game modes use `AdaptivePacer`.
     - Game modes use buffer 0, which is not paced at all (VideoRenderer.kt:534-535, 558-561; GameMode.kt:107-111).
     - `FramePacer` with a buffer of 1–2 runs only with `--ei jitter 1|2`, and `ConstantPlayoutPacer` only with `--es pacer cpd`.
     - Note: `VsyncClock`, which is on the daily path, lives in `FramePacer.kt:18`.
  3. The review did not mention two real costs:
     - `MainActivity` is `exported` (it is the launcher; AndroidManifest.xml:20-27), so any app on the tablet can start it with these extras.
     - The daily APK is the **debug** variant (`scripts/install-apk.sh:15`; there are no `buildTypes`). "Debug-only" therefore needs a runtime developer gate, not a build-type split. See Additional issue 3.
- Severity opinion: Low, agree. The value is in retiring dead experiments that sit in lifecycle-sensitive code: the GL path, `nw` sockets and idle refresh.

#### Experiment knob inventory (classification)
Legend:
- **keep**: a daily feature or a needed diagnostic, stays as is.
- **debug-only**: keep, but behind a single developer gate, and log it in the active-profile line.
- **retire**: remove the code. The experiment is concluded negative or no-effect, or was superseded.

| # | Side | Knob | Where (file:line) | Card / evidence | Class | Justification |
|---|---|---|---|---|---|---|
| 1 | C | `--ei jitter N` (fixed buffer 0–2, uses `FramePacer`) | MainActivity.kt:375-384; VideoRenderer.kt:368, 558 | T-016/T-052; GameJitter (GameMode.kt:107-111) | debug-only (retire the buffer 1–2 branch) | Adaptive pacing is the default (T-052). Buffer 0 is reachable via Game mode. Buffer 1–2 has no recorded on-device win since T-052. |
| 2 | C | `--ei hz N` | MainActivity.kt:411 | T-046 | debug-only | Default follows the stream (FrameRatePolicy). Useful for 60/120 A/B. |
| 3 | C | `--ei oprate 0/-1/-2/N` | MainActivity.kt:373; VideoRenderer.kt:285-286 | T-052; NOTES.md:315 | retire | HiSilicon decoder does not accept `KEY_OPERATING_RATE`/`KEY_PRIORITY` (`unset`). Keep the plain default of setting the rate to stream fps, or drop it too. |
| 4 | C | `--es render gl`, `--ei frate`, `--ez glpts` (GL path: GlPresenter 366 lines, ~51 refs in MainActivity) | MainActivity.kt:367-369, 432-437; GlPresenter.kt | T-018 done; T-019 **blocked/parked**; NOTES.md:132-136 | retire (needs orchestrator decision; close T-019 as won't-do) | HarmonyOS holds the GL surface at 60 Hz too. The T-019 jitter buffer was "worse to the eye" and had a cold-start no-frame bug. The surface path reaches 120 Hz (NOTES.md:1099-1104). The GL path doubles the Surface lifecycle paths (H02/M03 risk). |
| 5 | C | `--ez stats_1s true` | MainActivity.kt:371 | T-141 | keep (diagnostic) | Needed for measurement runs (NOTES.md:1095). Default 10 s window saves power. |
| 6 | C | `--ei inflight N` | MainActivity.kt:385; VideoRenderer.kt:448-453 | T-057; NOTES.md:342 | retire | inflight 3/4 measured worse (6.3/8.6 % repeats vs 0.2–7.1 % with the 6 ms lead). The card warns it can cause keyframe loops with FrameQueue. |
| 7 | C | `--ei lead_us N` | MainActivity.kt:386-389 | T-057/T-061; NOTES.md:376-381 | debug-only | Sweep concluded on a fixed 6 ms (`VsyncClock.DEFAULT_LEAD_NS`). Keep for re-tuning after an OS update. |
| 8 | C | `--ei deadline_us N` | MainActivity.kt:391-396 | T-071; NOTES.md:458-466 | debug-only | 6 ms default adopted. HarmonyOS reports 13.33 ms. Re-tune knob. |
| 9 | C | `--ez keep_jitter`, `--ez recenter` | MainActivity.kt:397-398; AdaptivePacer/VsyncClock fields | T-067 **blocked** (inconclusive, card :58) | retire (or finish T-067) | Off by default. The only measurement was confounded. Dead branches inside the default pacer. |
| 10 | C | `--es pacer cpd`, `cpd_q_permille`, `cpd_hold_us` | MainActivity.kt:400-405; ConstantPlayoutPacer.kt (139 lines); VideoRenderer.kt:377-379, 560 | T-080; NOTES.md:448-453 | retire | User felt the latency ("ikincisinde gecikme hissediliyor"). The default `lock` stays. Keep `tools/pacing/sim.py` as the offline reference; delete `ConstantPlayoutPacerTest` with it. |
| 11 | C | `--ez pace_trace true` | MainActivity.kt:406; PaceTrace.kt; Records.kt:51 (`stampOpens`) | T-069/T-073/T-077 | keep (diagnostic) | Source of all replay material (`tools/pacing`). Off = one volatile read. |
| 12 | C | `--ez crypto_bench true` | MainActivity.kt:408-410; Records.kt:59-107 | T-076; NOTES.md:421 | retire (or move to a JVM/instrumented test) | One-shot, concluded (AndroidOpenSSL is already the default, 776 MB/s). |
| 13 | C | `--ez perf_hint`, `--ei perf_hint_target_us` | MainActivity.kt:345-353; PerfHint.kt (178), AndroidPerfHint.kt; hooks VideoRenderer.kt:330-332, 405, 472-475 | T-079; NOTES.md:440 | retire | HarmonyOS 4.3: `createHintSession` returns no session (`session=0`), so the path is closed. The hooks sit in both decoder threads. |
| 14 | C | `--ei ping_ms` | WifiKnobs.kt:30; MainActivity.kt:310-315 | T-089 | debug-only | Keeps the 3 s PONG timeout contract. Harmless. |
| 15 | C | `--ei tos_ctl`, `--ei tos_video`, `--ez wifi_ll` | WifiKnobs.kt:31-33; MainActivity.kt:316-331; manifest WAKE_LOCK (AndroidManifest.xml:6-7) | T-089; NOTES.md:595-598 | retire | DSCP and `wifi_ll` had no effect (NOTES.md:597). Host `SERVICE_CLASS` covers QoS (T-124). Removes the WAKE_LOCK permission and WifiLockHolder. Revisit only under T-127. |
| 16 | C | `--ei rvote`, `rvote_min_fps`, `rvote_prio` (hidden-API reflection) | MainActivity.kt:294-308, 445; RefreshVote.kt:141-152 (186 lines) | T-140; NOTES.md:1083-1086 | retire | Negative: panel stays 100 % at 60 Hz. Uses `Class.forName("android.view.DynamicRefreshRateHelper")`, a hidden API that may break on an OS update. |
| 17 | C | `--ez audio false` | MainActivity.kt:415 | T-095 | debug-only | Panel has "Ses". The extra additionally drops the HELLO audio bit, which is useful for isolating audio. |
| 18 | C | `--es transport auto/usb/wifi` | MainActivity.kt:417-420 | T-096 | debug-only | Per-launch override, the stored setting is untouched. Useful for X8 USB/Wi-Fi A/B. |
| 19 | C | `--es audio_out aaudio/track/auto` | MainActivity.kt:485; AudioPlayout.kt:114; SinkPolicy.kt:24 | T-100/T-101 | debug-only | Duplicates the panel "Ses çıkışı" choice without saving. |
| 20 | C | `--ei audio_buf_bursts N` | AudioPlayout.kt:94; AudioBufferConfig.kt:14 | T-110/T-114 | debug-only, and fix its side effect | **Leaks into persisted daily state**: growth after an override is saved, and OutBufMemory only ratchets up (T-110 card :127). No reset exists (see D9). |
| 21 | C | `--ez quickack false` | MainActivity.kt:492-494; QuickAck.kt:32 | T-074; NOTES.md:415-418 | debug-only | Default-on proven by A/B (79 vs 1 late arrivals). Keep the off switch for A/B. |
| 22 | C | `--ez stall_diag true` | MainActivity.kt:495-496; diag/StallDetector.kt | T-120/T-142 | keep (diagnostic) | Already opt-in (NOTES.md:1088). |
| 23 | C | `--es net_bench host:port` (+`net_bench_s/_dir/_streams/_rcvbuf_kb`) | MainActivity.kt:357-365; bench/* (322 lines); manifest :29-33 | T-090 | debug-only (move to the `src/debug` source set) | Proved the NWConnection root cause. Rarely needed. Reachable via the exported launcher. |
| 24 | H | `MATEBRIDGE_FPS`, `MATEBRIDGE_BITRATE_KBPS` | VideoSettings.swift:77-82 | T-045/T-086 | debug-only | Env bitrate wins over STREAM_PREFS (VideoSettings.swift:20). It must show in the profile line or results are mislabelled. |
| 25 | H | `MATEBRIDGE_CODEC=h264`, `MATEBRIDGE_H264_PROFILE` | VideoSettings.swift:83; EncoderKnobs.swift:166 | T-082/T-086; NOTES.md:538 | debug-only (H264_PROFILE: retire) | H.264 can't do 120 fps at 2800×1840 on M6. Keep codec for compatibility debugging. The client decodes both. |
| 26 | H | `MATEBRIDGE_REFRESH=60/120` | VideoSettings.swift:84-85; StreamCoordinator.swift:190, 376 | T-017 | debug-only | Default derived from fps. |
| 27 | H | `MATEBRIDGE_FRAME_DELAY=0/1` | VideoSettings.swift:86 | T-017 card :48-50 | retire | Never measured or adopted ("MaxFrameDelayCount ayarlanmaz"). |
| 28 | H | `MATEBRIDGE_ENCODER=llrc/fast` | HEVCEncoder.swift:132-134 | T-053/T-087 | debug-only | `fast` is the default at every fps. `llrc` only at ≤60 fps (~10 ms/frame). |
| 29 | H | `MATEBRIDGE_IDLE_REFRESH_MS/_COUNT/_KEY/_BUFFER/_QP` (timer, QP boost, copy pool) | EncoderKnobs.swift:81-90; HEVCEncoder.swift:71-86, 124-126, 206-223, 338-391, 430+ | T-086/T-087; NOTES.md:566-581 | retire | Ineffective on the real path: 222-byte skip frames, the `fast` profile ignores mid-stream QP, and the bench gain was a warm-up artefact. When on, it adds a third (timer) caller into the encoder, the M02 surface. |
| 30 | H | `MATEBRIDGE_PRIO_SPEED=0`, `MATEBRIDGE_QUALITY` | EncoderKnobs.swift:164-165 | T-086; NOTES.md:546-548 | PRIO_SPEED: retire; QUALITY: debug-only | PRIO_SPEED=0 gives ~25 ms encode and is unusable. QUALITY is a possible future text-clarity profile. |
| 31 | H | `MATEBRIDGE_KEYFRAME_INTERVAL_S` | KeyframeIntervalPolicy.swift:20 | T-075 | debug-only | 300 s default adopted. |
| 32 | H | `MATEBRIDGE_INPUT_RETAG=0` | InputColorTags.swift:38 | T-113; NOTES.md:777-806 | retire | The fix is proven (−2.7 ms and correct colour). `=0` reproduces a known colour/latency bug. |
| 33 | H | `MATEBRIDGE_WIFI_BITRATE_KBPS` | TransportBitrate.swift:22 | T-088 | debug-only (input to H03) | The only Wi-Fi bitrate cap today. H03 should replace it with measured adaptation. |
| 34 | H | `MATEBRIDGE_SERVICE_CLASS` | TransportKnobs.swift:43 | T-088/T-124 | debug-only | `signaling` adopted as default (NOTES.md:959). |
| 35 | H | `MATEBRIDGE_VIDEO_SOCKET=nw`, `MATEBRIDGE_CONTROL_SOCKET=nw` (Network.framework listeners and connections in SessionServer) | TransportKnobs.swift:95, 153; SessionServer.swift:34-38, 112-115, 336-375, 561-600, 955-987, 1125-1205 | T-091/T-092/T-111; NOTES.md:620-631 | retire | NWConnection's user-space TCP: 4.2 % retransmits and a ~27 Mbps ceiling on Wi-Fi. `bsd` is the default on both. Removing it takes a large share of SessionServer's dual-stack code. Check that the Bonjour TXT path (T-128 :83) stays on `BonjourAdvertiser`. |
| 36 | H | `MATEBRIDGE_NOTSENT_LOWAT_KB` | TransportKnobs.swift:112 | T-091 | debug-only (H03 tuning) | 128 KB default. |
| 37 | H | `MATEBRIDGE_SENDQ_LOG`, `MATEBRIDGE_LAT_TRACE` | TransportKnobs.swift:75; LatencyCsv.swift:13 | T-070/T-088 | keep (diagnostic) | Needed for H03/H05/M07 traces. |
| 38 | H | `MATEBRIDGE_TCP_LOG` | TcpInfoLog.swift:140 | T-126 | keep (diagnostic) | Default auto (Wi-Fi only). |
| 39 | H | `MATEBRIDGE_AUDIO=off` | AudioStreamer.swift:35 | T-094 | debug-only | Isolation switch. |
| 40 | H | CLI `--dump-video`, `--encode-bench`, `--sharpness-bench`, `--inject-test` | main.swift:6-9 | T-011/T-047/T-086/T-023 | keep (tooling; optionally move to a separate executable target) | Benches are the only reproducible host-side measurements. `--inject-test` posts real input events. Moving them out of the app binary is optional. |
| — | — | `MATEBRIDGE_SIGN_IDENTITY` | scripts/bundle-host.sh | T-006 | keep | Build-time, not runtime. |
| — | C | `--ei draw_scale` | (gone) | T-144 reverted | already retired | Confirms the review's "measure-and-revert" praise (F1). |

Summary of the table:
- Retire: client 3, 4, 6, 9, 10, 12, 13, 15, 16; host 25 (`H264_PROFILE` only), 27, 29, 30 (`PRIO_SPEED` only), 32, 35.
- debug-only: about 17 knobs.
- keep: 6.

### L03 — Copy and frequent-OS-query cost should be measured (client side only)
- Verdict: PARTIALLY CORRECT (copies exist; the client cost is already measured on device and is small)
- Evidence (video frame copies on the client, in order):
  1. Socket read into a 64 KiB chunk buffer (SessionController.kt:809, 828).
  2. `RecordDecoder.feed` arraycopy into the ring buffer (Records.kt:254-268), plus occasional growth copies.
  3. AES-GCM `doFinal` into the reused `scratch` (Records.kt:197). Inherent.
  4. `plain.copyOfRange(1, n)` (Records.kt:283). New array.
  5. `Codec.decodePayload` → `r.bytes(size)` (Codec.kt:61, 378). New array again.
  6. `buf.put(frame.data.value)` into the MediaCodec input buffer (VideoRenderer.kt:465-466). Inherent for the Java MediaCodec API.

  Copies 4 and 5 are avoidable: two allocations and copies per frame, about 2 × 7.5 MB/s of garbage at 60 Mbps.
- Device evidence already exists:
  - T-077 (NOTES.md:437): codec input copy 0.11 ms p50; `queueInputBuffer` 0.58 ms p50 (the dominant cost); in-app decrypt `init` 0.34 ms plus `doFinal` 0.16 ms.
  - T-076 (NOTES.md:421): the earlier "~11 ms" keyframe decrypt came from "four copies + allocation" and was fixed.
  - The control-path sealer (Records.kt:150-160) copies twice, but on small messages.
- Corrections:
  - The review's line ref C12:454-472 is close: the real copy is at :465-466.
  - The review did not note that the client copy cost was already measured (T-076/T-077), or that `queueInputBuffer` (a binder call) dominates, not the copy.
  - The remaining unknown is GC pressure from copies 4 and 5. `AudioArrivalMeter` already logs `gc_count`/`gc_time_ms` on audio gaps (T-117), so it can be correlated without new tooling.
- Severity opinion: Low, agree. The client side is low and possibly lowest priority. Don't build pooling before a GC correlation shows a cost.

### W4 — Thread map (rows "Android codec", "Ses/Audio", and the closing verdict paragraph)
- Verdict: CONFIRMED with one nuance (audio)
- Evidence, Android codec row:
  - Input thread `mb-decoder` (VideoRenderer.kt:257) and output thread `mb-decoder-out` (VideoRenderer.kt:403-431). Synchronous dequeue on two threads, not the async callback API. The pipeline overlaps by design (T-052).
  - Teardown ownership, as cited for M03:
    - `retire()` joins 300 ms (JOIN_MS, VideoRenderer.kt:51, 262-270).
    - The next `decodeLoop` does an unbounded `att.previous?.join()` (VideoRenderer.kt:327).
    - `runCodec` `finally` joins the output thread for 500 ms, then calls `codec.stop()`/`release()` regardless (VideoRenderer.kt:481-487).
- Evidence, audio row:
  - Writer thread `mb-audio-<id>` per `Stream` (AudioPlayout.kt:279). The producer is the control reader thread.
  - The JNI layer is 247 lines (mbaudio.cpp). The native `Out` is opened, written and closed by that one writer only (mbaudio.cpp:3-5; AAudioSink.kt:95-99).
  - Nuance: the new stream waits only `PREVIOUS_JOIN_MS = 500` ms for the previous writer (AudioPlayout.kt:298-303, 686). `AAudioSink.interrupt()` is a no-op (AAudioSink.kt:93), and a blocked write can last up to 1 s in the start grace (AAudioSink.kt:102-104). Two generations' native streams can therefore briefly coexist. The new one falls back via the EXCLUSIVE→SHARED→TRACK chain (SinkPolicy.kt:93-96).
  - So the review's "native stream managed by a single writer" holds per stream, not across generations. It is the same "bounded wait, then proceed anyway" pattern as M03, at lower stakes.
- Closing paragraph ("generally reasonable; don't go single-thread nor add threads; simplify lifecycle and generation ownership"): agree.
  - Client threads are all named with a generation suffix where relevant: `mb-ctl-read-$gen`, `mb-ctl-write-$gen`, `mb-video-$gen`, `mb-audio-$id` (SessionController.kt:600, 648, 800; AudioPlayout.kt:279).
  - That makes the thread-count trend for D10 cheap to observe.
- Severity opinion: agree (descriptive). The audio overlap is Low.

### SE6 — No unbounded raw-frame list or obvious deadlock; close-once, bounded mailboxes good; "no leak" needs long measurement
- Verdict: CONFIRMED
- Evidence:
  - `BsdTcpSocket` documents and implements close-exactly-once with a single closed-handler dispatch (BsdTcpSocket.swift:252, 471-497).
  - The client `RecordDecoder` buffer is capped at `bufferCap` and fails with `BUFFER_OVERFLOW` (Records.kt:241, 257-260).
  - The native AAudio `destroy` stops, closes and frees on all paths; open error paths close the stream or builder (mbaudio.cpp:69-76, 104-111, 125-150).
  - The only sustained measurement is 30 minutes from 2026-09-30 (Mac RSS 64 MB flat, tablet PSS 68–73 MB; NOTES.md:150-155). It predates audio, files, sleep/WoL and game modes.
- Corrections: none. One minor non-issue I checked: the `mb-pace-trace` executor (VideoRenderer.kt:102-104) is never shut down. It exists only with `pace_trace` on and only once per renderer, which is reused per Activity (MainActivity.kt:1151, 1188), so it is not a repeating leak.
- Severity opinion: agree. Measurement is the item (D10).

### SE8 — AAudio dlopen handle intentionally kept; not a repeating leak
- Verdict: CONFIRMED
- Evidence:
  - `resolveIsMMapUsed()` calls `dlopen("libaaudio.so", RTLD_NOW|RTLD_NOLOAD)` and never `dlclose`s (comment at mbaudio.cpp:55).
  - It is called only through a function-local `static const IsMMapUsedFn fn = resolveIsMMapUsed();` (mbaudio.cpp:60). C++11 guarantees one thread-safe initialisation per process, so the refcount is raised once. The library is linked anyway (CMakeLists.txt:6 `target_link_libraries(mbaudio aaudio dl)`).
- Corrections: none. The review's measurement suggestion (share close/open, long Surface churn) is fine. Share close/open belongs to DavServer (other verifier).
- Severity opinion: agree (not an issue).

### PF4 — Zero-copy base right; compressed byte conversions, crypto copies, codec input copy exist (client half)
- Verdict: CONFIRMED (client half)
- Evidence:
  - The decoder outputs straight to the Surface: `codec.configure(format, surface, null, 0)` (VideoRenderer.kt:305), with no `getOutputBuffer`/`Image`/`Bitmap` use anywhere in `video/`.
  - The GL path uses SurfaceTexture on the GPU (GlPresenter.kt).
  - The copy chain is under L03.
- Corrections: none. The review is right that the client is "not zero-copy". Two of the client copies are avoidable (L03); the others are inherent to the Java crypto and MediaCodec APIs.
- Severity opinion: Low.

### X11 — Image-quality test row: thin coloured text, B/W ramps, moving pattern → chroma/range/gamma, readability, bitrate
- Verdict: CONFIRMED (gap is real; partial infrastructure exists)
- Evidence:
  - There is no colour-ramp, limited/full-range or thin-coloured-text test in NOTES, cards or code.
  - `--sharpness-bench` measures **luma** PSNR/SSIM only (SharpnessBench.swift:17). Its reference chroma is already 2×2-averaged at source (SharpnessBench.swift:41-46, 121), so it cannot see 4:2:0 loss against RGB.
  - On-device screenshot PSNR fails: it is stuck at ~33.7 dB from colour management (NOTES.md:562).
  - T-113 found and fixed a real colour/gamma error: +8 luma levels from a 709→sRGB conversion (NOTES.md:777-806). This is exactly the kind of error X11 targets.
  - PLAN.md:86, 178 already lists a 4:4:4 experiment for Phase 5, noting that the tablet decoder may not support it.
- Corrections: the review doesn't note that a bench harness exists to extend. The cheapest step is adding an RGB-referenced chroma metric and test patterns to `SharpnessBench`, followed by one human on-device viewing.
- Severity opinion: agree it's a later item (colour after trust/health/display).

### D8 — Few power/quality profiles; full res for text; don't render 120 when panel is 60; verify hardware and thermals; document SDR limit; exit: profile change reliable, real Hz visible, no needless spikes, experiments out of daily settings
- Verdict: ALREADY ADDRESSED (mostly) — decisions 0013, 0014, 0016; T-109, T-141, T-143
- Evidence:
  - Five stream modes are in the panel: Netlik 60/100 %, Akıcı 120/100 %, Performans 120/75 %, Oyun 120/66 %, Oyun 60/100 % (`StreamMode.kt:10-19`).
  - "Oyun 60" exists precisely for the panel-60 case (decision 0016; NOTES.md:1088-1097: Mac GPU 90 % → 54 %).
  - The real panel Hz shows in the overlay ("Mod %.0f Hz", StatsFormat.kt:63). `display_rate` feedback thins host fps to the panel rate (NOTES.md:350-352).
  - Host encoder hardware is read back and logged (HEVCEncoder.swift:287, `Hardware=`). The client logs `codec.name` (VideoRenderer.kt:322-323, e.g. `OMX.hisi…`), but not `MediaCodecInfo.isHardwareAccelerated`.
  - Thermals: 5 minutes of gaming, SoC ~37–40 °C, no frequency drop (NOTES.md:1086, 1092).
  - Experiment knobs are not in the settings UI (L02).
- Corrections:
  - The open parts are small: document the SDR/4:2:0 limit (with X11), and optionally add `is_hw=` to the client `codec_start` line.
  - "Wi-Fi balanced" is not a profile today. Wi-Fi only has the host env cap (#33), which belongs to H03.
- Severity opinion: lower than implied. Most of D8 is done.

### D9 — (my parts) README/build ID/supported version pair; factory or known-good reset for all settings
- Verdict: CONFIRMED (gaps), with partial existing pieces
- Evidence:
  - README and build ID: see L01.
  - Supported version pair: macOS 27.0.1 is in PLAN.md:9, but no HarmonyOS build or app SHA pair is recorded.
  - Settings reset:
    - The client has no reset. Prefs files are `matebridge` (Settings.kt keys), `matebridge_pairkeys` and `matebridge_audio`. The last holds learned state (`OutBufMemory`, `SafetyMemory`) that ratchets up, including from an experiment override (T-110 card :127).
    - The host menu has only "Onaylı cihazları unut" (main.swift:91). Stream prefs per device live in UserDefaults (`UserDefaultsStreamPrefsStore.swift:4-13`), with `usbModeEnabled` and clipboard keys alongside (main.swift:190-236). There is no reset item.
  - Permission and login startup checks partly exist:
    - `CGPreflightScreenCaptureAccess` (ScreenCapture.swift:42);
    - the Accessibility line in the menu (main.swift:66-72, AccessibilityPermission.swift:15);
    - login item status (LoginItem.swift:19-44).
- Corrections: the review omits that the learned audio state can be pushed up by an experiment and is only clearable through Android "clear data", which also wipes the pairing key.
- Severity opinion: Low–Medium. The reset matters for "known-good" recovery.

### D10 — One-week real-workload resilience (8 h soak, then ≥1 week; restarts, release errors, gaps, memory/thread/FD trend)
- Verdict: NOT VERIFIABLE IN CODE (needs device); confirmed as missing evidence
- Evidence:
  - This is literally PLAN's own Phase 4 exit (PLAN.md:173: "Bir hafta boyunca günlük iş için kullanılıyor, 'yeniden başlatmam gerekti' türünden sorun kalmıyor"). It is not yet claimed as met.
  - The only long run is 30 minutes (NOTES.md:150-155).
  - The monitoring scripts that would make it reproducible are scratch-only (NOTES.md:1117).
- Corrections: none. The review's metrics are right.
- Severity opinion: Medium. It is the gate for the "sole main screen" claim (F4/F5).

### F1 — Strengths to protect (pen pressure/proximity/ownership, release safety, reference-aware frame queue, pairing, real-device findings; pure state machines; measure-and-revert, e.g. T-144)
- Verdict: CONFIRMED
- Evidence:
  - Pure state machines: `MateBridgeCore` (SessionMachine.swift, InputStateMachine*, InjectionPlanner) and Kotlin `SessionMachine.kt`, all with extensive tests (P3).
  - Measure-and-revert: T-144 was reverted with decision 0017 withdrawn (git log `ceb5652`, `19bbbda`; NOTES.md:1099-1112). Other reverts include T-057/T-060/T-061 (NOTES.md:362-366), T-080 cpd kept off and T-140 kept off.
- Corrections: none.
- Severity opinion: n/a.

### F3 — Simpler: few verified profiles; experiment modes to a debug area; Display/Session/Media owners; keep keyframe gate, release latches, encrypted handshake
- Verdict: PARTIALLY CORRECT
- Evidence:
  - Profiles already exist (D8).
  - The "debug area" is not separate. Knobs are launch extras on the exported, daily (debug-variant) APK and env vars on the daily host (L02).
- Corrections: "debug area" must be a runtime developer gate, because the daily APK is the debug build. The owner split (A1) is outside my scope.
- Severity opinion: agree it's simplification, not urgent.

### F4 — Level today: personal beta; not proven as long-term sole main screen; Wi-Fi drawing and network work; trust risk; codec-failure input gap
- Verdict: CONFIRMED (my parts: no long-term evidence; codec-failure gap visible at MainActivity.kt:1154)
- Evidence:
  - D10. Wi-Fi pen bunching is still parked (PLAN.md:181).
  - `onGiveUp` only logs: `MbLog.e("decoder_give_up", …)` at MainActivity.kt:1154.
- Corrections: none.
- Severity opinion: agree.

### F5 — Decision order: USB reference plus second access path; fix trust, input stop on image fault, persistent display; then e2e measurement; then Wi-Fi with Mac Ethernet; pen/energy/colour later; before main-screen acceptance: H01–H05 validation, M01–M04 race tests, recovery runbook, ≥1 week evidence
- Verdict: CONFIRMED (as a sensible plan; consistent with repo state)
- Evidence:
  - T-127 (the Mac Ethernet re-evaluation) is the only `todo` card and is already deferred behind measurement.
  - D10 equals the PLAN Phase 4 exit.
  - The M01–M04 race tests require seams (M07 correction 2).
- Corrections: put CI (cheap) before or alongside the race-test work, so those tests actually gate merges.
- Severity opinion: agree.

### A2 — Keep: … hardware notes, golden fixtures, pure state machines, fuzz tests (my bullet)
- Verdict: CONFIRMED
- Evidence:
  - Hardware notes: NOTES.md, 1120 dated lines.
  - Golden fixtures: 48 `.hex` plus `crypto_vectors.json`, checked by `check.sh` (P2).
  - Pure state machines: F1.
  - Fuzz tests: InputFuzzTests.swift, KeyboardFuzzTests.swift, InputFuzzTest.kt.
  - Private API isolation (adjacent bullet): `CGVirtualDisplay` is referenced only in `VirtualDisplay.swift`. `DisplayWakePolicy.swift:4,8` mentions it in comments only. The undocumented gesture type is isolated in `MagnifyGestureEvent.swift` (decision 0009).
- Corrections: none.
- Severity opinion: n/a.

---

## Additional issues found

1. **`gen.py` regenerates on any invocation without `--check`** (protocol/fixtures/gen.py:460-476): `check = "--check" in sys.argv`, otherwise it writes all fixtures. `--help`, a typo or `--chek` silently rewrites the golden vectors. Today the output is deterministic, so nothing changed (I triggered it by accident; `git status` stayed clean). For a file that "only the orchestrator changes", a safer CLI is an explicit `--write` and failing on unknown arguments. Low. Owner: orchestrator.
2. **`scripts/check.sh` is Mac-only in practice and monolithic:**
   - It hard-codes the macOS Android Studio JBR and SDK paths (check.sh:24-26).
   - It runs the CryptoKit vector script (check.sh:39-42).
   - It builds all 4 probes (check.sh:16, 27).
   - On a Linux runner with Swift present, `swift build` of `host-mac` fails. CI needs component flags (CI-1). Low.
3. **The exported launcher plus the debug-variant daily APK means experiment knobs are reachable by any app on the tablet:**
   - AndroidManifest.xml:20-27 exports `MainActivity`; MainActivity.kt:357-496 reads 32 extras.
   - Examples: `net_bench` (forwards to `NetBenchActivity`, which connects to an arbitrary host:port, MainActivity.kt:358-365), `quickack false`, `transport wifi`, `audio false`, `render gl`, `pace_trace true` (writes `cache/pace_trace.csv`).
   - The debug `VideoTestActivity` is also `exported="true"` (src/debug/AndroidManifest.xml:5-6), and the daily APK is debug (`install-apk.sh:15`).
   - Impact is low on a single-user tablet without Play Store apps, but it supports gating knobs behind one developer switch (E-1).
4. **An experiment override persists into daily learned state:** `audio_buf_bursts` growth is saved, and `OutBufMemory` only ratchets up (T-110 card :127; AudioPlayout.kt:94). There is no reset path short of "clear data", which also deletes `matebridge_pairkeys`. Low. Fixed by RESET-C.
5. **No test target for `MateBridgeHost`, and no codec seam in `VideoRenderer`** (Package.swift:18; VideoRenderer.kt:276-305). The review's M02/M03/H02 deterministic tests cannot be written until a small seam is extracted. This should be in the acceptance criteria of those cards, not discovered mid-task. Medium as a planning risk.
6. **Audio generation overlap** (W4): the new writer proceeds after 500 ms while the old writer can still be blocked in `AAudioStream_write` for up to 1 s (start grace), and `interrupt()` is a no-op (AudioPlayout.kt:298-303; AAudioSink.kt:93, 102-104). The consequence is a fallback to SHARED or TRACK for that stream (degraded latency), not a crash. Low. Worth a line in the X6/D10 churn checklist (count `audio_previous_slow` and `api=` fallbacks).
7. **Two avoidable per-frame copies and allocations on the client video path** (Records.kt:283 `copyOfRange`, Codec.kt:61/378 `r.bytes`). Measured cost is small (L03). Only act if a GC correlation shows stalls.
8. **PLAN.md is stale in ways that mislead agents** (PLAN.md:10, 167-169, 179). See P1.

---

## Proposed work items

### CI-1 — Add a GitHub Actions merge gate (macOS Swift + Linux Android + protocol checks)
- owner: orchestrator. It owns merges and `scripts/`, and decides on runner cost.
- depends_on: none.
- Decision record: yes, short (new tooling and third-party Actions).

  > Draft 0018 "CI on GitHub Actions": Every push to `main` and every `task/*` branch runs `scripts/check.sh` split by component on GitHub-hosted runners:
  > - `macos-15` (or newer): `swift build` + `swift test` for `host-mac`, the crypto-vector diff and the fixture check;
  > - `ubuntu-latest`: `./gradlew assembleDebug testDebugUnitTest` for `client-android` with JDK 21, SDK platform 37, NDK 30.0.16248370 and CMake 4.1.2 installed via sdkmanager, plus the fixture check.
  >
  > Probes are excluded from CI. Only first-party `actions/*` plus `actions/setup-java` and the runner's preinstalled sdkmanager are used (no third-party Android action). Hardware-dependent behaviour (CGVirtualDisplay, SCK, VT, MediaCodec, TCC) is explicitly out of CI. The local `check.sh` stays the authoritative pre-handoff gate. CI is advisory for the first week (to catch flaky timing tests), then required for merges.
  >
  > macOS minutes on private repos bill at a multiplier, so the macOS job runs on pushes touching `host-mac/**`, `protocol/**` or `scripts/check.sh`.

- Wire protocol change: none.
- files: `.github/workflows/check.yml` (new), `scripts/check.sh`, `docs/decisions/0018-ci-github-actions.md` (new), `docs/WORKFLOW.md` (one line on the merge gate).
- Goal: make the existing local gate reproducible and visible per commit, without pretending hardware behaviour is tested. Catch Swift/Kotlin build and test regressions, stale fixtures and crypto-vector drift before merge.
- Out of scope: device tests, instrumentation tests, emulator runs, release signing, building probes.
- Acceptance criteria:
  - [ ] `check.sh` accepts `--only host|android|protocol` (default: all, same behaviour as today). It does not probe macOS-only paths when `JAVA_HOME`/`ANDROID_HOME` are already set. (Local + CI.)
  - [ ] The workflow runs `check.sh --only host` and `--only protocol` on macOS, and `--only android` and `--only protocol` on Linux. (CI.)
  - [ ] A deliberately stale fixture on a test branch fails the job. (CI.)
  - [ ] Wall time is under 15 min per job with Gradle and SwiftPM caches. (CI.)
  - [ ] NOT covered and stated in the decision: SCK, VT, CGVirtualDisplay, MediaCodec, AAudio, TCC, CGEvent posting.
- Plan hints:
  - Host tests are Core-only and fake Keychain and mDNS. Socket tests bind loopback, which works on hosted runners.
  - Watch for timing-sensitive tests (e.g. the 5 s Keychain bound in KeychainAsyncTests, socket deadlines). Run advisory first.
  - Android needs network access to `services.gradle.org`, `dl.google.com`/`maven.google.com` and the sdkmanager repos.
  - `swift-tools-version: 6.0` with `import Testing` needs Xcode 16+.

### DOC-1 — Rewrite README to current state; refresh PLAN status lines; record the supported version pair
- owner: orchestrator (docs; PLAN is orchestrator-owned).
- depends_on: BUILDID-C, BUILDID-H (so the README can name how to read the build ID).
- Decision record: no. Wire protocol change: none.
- files: `README.md`, `docs/PLAN.md` (hardware table, Phase 4/5 status lines only).
- Goal: README becomes the single "current product state" page. It covers:
  - what works (display, pen, keyboard/trackpad, audio, clipboard, tablet files over USB, sleep/WoL, modes);
  - known limits (Wi-Fi ~40 ms vs USB ~24 ms; decoder-failure gap; display removed after a 10 s grace);
  - the last verified pair (macOS build plus HarmonyOS build plus host/client SHA);
  - a short recovery list (Parsec/physical monitor, "Onaylı cihazları unut", USB mode).

  NOTES stays the research log.
- Out of scope: a full runbook (that is a separate M06 item), screenshots.
- Acceptance criteria:
  - [ ] There is no "Phase 0 / Nothing usable" text.
  - [ ] Layout lists `tools/`, `install-apk.sh`, `usb-mode.sh`, `bundle-host.sh`.
  - [ ] The PLAN hardware table and Phase 4/5 checkboxes match BOARD/NOTES; the stale "~90 fps / 13–15 ms" line is corrected.
  - [ ] "Last verified" names commit SHAs and OS builds.
- Plan hints: pull facts from NOTES 2026-10-02/03 and the decisions 0011–0016 titles.

### BUILDID-C — Client build identity in BuildConfig, log start line and settings "About" row
- owner: android-client-dev. depends_on: none.
- Decision record: no (no new dependency; Gradle `providers.exec` for `git`).
- Wire protocol change: none. Optional future: an app version field in HELLO is a protocol change and is NOT part of this card.
- files: `client-android/app/build.gradle.kts`, `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (one log call in `onCreate`), `client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt` (read-only "Sürüm" row), new `client-android/app/src/main/kotlin/dev/matebridge/client/BuildInfo.kt`, `client-android/app/src/test/kotlin/dev/matebridge/client/BuildInfoTest.kt`.
- Goal: every log capture and acceptance result can name the exact client build.
  - Add `buildFeatures { buildConfig = true }` and `BuildConfig.GIT_SHA` (short, with `-dirty` when the tree is dirty), `BUILD_TIME_UTC`, and `versionCode` from the commit count.
  - Log `ev=app_start version=… sha=… built=… sdk=… os_build=Build.DISPLAY` once in `onCreate`. No serial number and no device ID.
- Out of scope: host side, protocol fields, release signing.
- Acceptance criteria:
  - [ ] JVM test: `BuildInfo.logFields()` format, and fallback `sha=unknown` when git is unavailable at build time.
  - [ ] `assembleDebug` works from a source tarball without `.git` (falls back to unknown).
  - [ ] Device: `adb logcat -s MB:*` shows one `app_start` line per cold start, and the settings panel shows the same SHA. (Tablet.)
- Plan hints: AGP 8+ disables BuildConfig by default. Use `providers.exec { commandLine("git","rev-parse","--short","HEAD") }` with `isIgnoreExitValue = true`. Keep configuration-cache friendliness in mind.

### BUILDID-H — Host build identity: commit in Info.plist, start log line, menu version line
- owner: mac-host-dev. depends_on: none.
- Decision record: no. Wire protocol change: none.
- files: `scripts/bundle-host.sh`, `host-mac/Resources/Info.plist`, `host-mac/Sources/MateBridgeApp/main.swift`, new `host-mac/Sources/MateBridgeCore/Session/BuildInfo.swift`, `host-mac/Tests/MateBridgeCoreTests/Session/BuildInfoTests.swift`.
- Goal:
  - `bundle-host.sh` writes `MBGitCommit` (short SHA, `-dirty` if needed) next to the existing timestamp `CFBundleVersion`.
  - On launch the host logs `ev=app_start version=0.x build=<CFBundleVersion> sha=<MBGitCommit> os=<ProcessInfo.operatingSystemVersionString>`.
  - The menu shows a disabled "Sürüm …" line.
- Out of scope: client side, protocol, notarization.
- Acceptance criteria:
  - [ ] XCTest: `BuildInfo` parses an Info.plist dictionary with missing keys as `unknown`.
  - [ ] `swift run` (no bundle) logs `sha=unknown` without crashing. (Mac.)
  - [ ] A bundled app shows the same SHA in `host.log` and the menu. (Mac.)

### KNOB-0 — Decision record: experiment knob policy and classification
- owner: orchestrator. depends_on: none.
- Decision record: yes.

  > Draft 0019 "Experiment knobs":
  > - Every experiment knob (client launch extra, host `MATEBRIDGE_*` env, CLI mode) is listed in one table in `docs/LOGGING.md` or a new `docs/KNOBS.md` with: card, default, class (keep / debug-only / retired) and outcome.
  > - New knobs default to off and must name the card that will adopt or retire them. A knob whose experiment concluded is retired within the closing card or an immediate follow-up.
  > - debug-only knobs on the client are honoured only when a developer switch is set (`--ez dev true` on the same launch, or a hidden toggle). The daily APK is the debug variant, so a build-type split is not enough.
  > - Each side logs one `ev=profile` line at session start with the effective stream mode, fps, scale, bitrate, pacer and the list of non-default knobs.
  > - GL presentation (T-018/T-019), the Network.framework socket paths (T-091/T-111), idle refresh (T-086/T-087), perf hint (T-079), refresh vote (T-140), cpd pacer (T-080), the inflight limit (T-057) and the Wi-Fi TOS/WifiLock knobs (T-089) are retired. T-019 and T-067 close as won't-do.

- Wire protocol change: none.
- files: `docs/decisions/0019-experiment-knobs.md`, `docs/KNOBS.md` (new; the table from this report), `backlog/tasks/T-019-*.md`, `backlog/tasks/T-067-*.md` (status).
- Goal: freeze the classification before any code removal, so implementers don't re-litigate experiments.
- Acceptance criteria:
  - [ ] Table covers all 33 client extras, 25 host env vars and 4 CLI modes, with file refs.
  - [ ] User confirms the GL path and `nw` retirement (both were "kept as option" informally).

### KNOB-C1 — Client: retire concluded experiments (perf hint, refresh vote, cpd pacer, oprate, inflight, keep_jitter/recenter, crypto bench, TOS/WifiLock)
- owner: android-client-dev. depends_on: KNOB-0.
- Decision record: covered by 0019. Wire protocol change: none.
- files: `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt`, `.../video/{VideoRenderer,AdaptivePacer,FramePacer,PerfHint,AndroidPerfHint,RefreshVote,ConstantPlayoutPacer,OperatingRate}.kt`, `.../session/{WifiKnobs,SessionController}.kt`, `.../security/Records.kt` (bench only), `client-android/app/src/main/AndroidManifest.xml` (WAKE_LOCK), corresponding tests under `client-android/app/src/test/...` (`PerfHintTest`, `RefreshVoteTest`, `ConstantPlayoutPacerTest`, `LockRecenterTest`, `WifiKnobsTest`).
- Goal: remove dead branches from the daily video and session path without changing default behaviour. `VsyncClock` stays; move it out of `FramePacer.kt` only if `FramePacer` is deleted.
- Out of scope: the GL path (KNOB-C2), `net_bench` (KNOB-C3), any default change.
- Acceptance criteria:
  - [ ] All default-path JVM tests pass unchanged: Pacing, AdaptivePacer, SparseFrameNoHold, PresentationScheduling, NewestFrameShown.
  - [ ] `ev=present`/`stats` field names used by `tools/pacing` are unchanged.
  - [ ] Device smoke: Akıcı and Oyun 120 for 2 min each; `latency_us` and `shown` comparable to NOTES 2026-10-03; no `detach_slow`. (Tablet.)
- Plan hints:
  - `ConstantPlayoutPacerTest` replays `tools/pacing/trace7_120hz_excerpt.csv`. Keep the CSV, because `SparseFrameNoHoldTest` uses it too.
  - The `rvote` driver touches the root View (MainActivity.kt:445, 1790).
  - Remove `pace_trace` probe plumbing only where it is cpd-specific.

### KNOB-C2 — Client: retire the GL presentation path
- owner: android-client-dev. depends_on: KNOB-0.
- Wire protocol change: none.
- files: `.../MainActivity.kt`, `.../video/GlPresenter.kt` (delete), `.../stream/GameMode.kt` (`GameJitter.Source.GL`), `client-android/app/src/main/res/layout/activity_main.xml` (`video_gl`), related tests.
- Goal: one Surface lifecycle (SurfaceView) instead of two. This reduces H02/M03 surface churn paths.
- Acceptance criteria:
  - [ ] JVM tests pass.
  - [ ] Device: 20× background/foreground and 10× mode switches; no black screen and no `gl_*` lines. (Tablet.)
- Plan hints: about 51 GL references in MainActivity. `codecReportsShown = !glMode` becomes `true`.

### KNOB-C3 — Client: developer gate for debug-only extras and `ev=profile` line; move NetBench to `src/debug`
- owner: android-client-dev. depends_on: KNOB-0, BUILDID-C.
- files: `.../MainActivity.kt`, new `.../session/DevKnobs.kt`, `.../bench/*` → `client-android/app/src/debug/kotlin/...`, `client-android/app/src/main/AndroidManifest.xml`, `client-android/app/src/debug/AndroidManifest.xml`, tests.
- Goal:
  - debug-only extras take effect only with `--ez dev true` in the same launch. Otherwise they are ignored and logged as `ignored=<keys>`.
  - One `ev=profile` line at `installConfig` lists the effective mode and the non-default knobs.
- Acceptance criteria:
  - [ ] JVM test: `DevKnobs.parse` ignores debug-only keys without `dev`, and lists them.
  - [ ] Device: `am start … --ei jitter 1` without `dev` → `ignored=jitter`; with `dev` → applied. (Tablet.)

### KNOB-H1 — Host: retire concluded experiments (`nw` sockets, idle refresh, FRAME_DELAY, PRIO_SPEED, H264_PROFILE, INPUT_RETAG=0) and add `ev=profile`
- owner: mac-host-dev. depends_on: KNOB-0.
- Wire protocol change: none.
- files: `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`, `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`, `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`, `host-mac/Sources/MateBridgeCore/Video/{EncoderKnobs,VideoSettings,InputColorTags}.swift`, `host-mac/Sources/MateBridgeHost/Video/{SharpnessBench,EncodeBench}.swift` (knob plumbing only), tests `TransportKnobsTests.swift`, `EncoderKnobsTests.swift`, `IdleRefreshRefineTests.swift`, `ExperimentKnobTests.swift`, `InputColorTagsTests.swift`.
- Goal:
  - Remove the Network.framework listener and connection variants and the idle-refresh timer, QP boost and copy pool.
  - Log one `ev=profile` line per stream start with the effective fps, bitrate, codec, encoder profile and non-default env knobs (extend the existing `listening` fields).
- Out of scope: changing any default, the H03 bitrate work.
- Acceptance criteria:
  - [ ] XCTest: knob parsers for the removed keys are gone, and the remaining knob tests pass.
  - [ ] `ControlSocketTests`/`BsdTcpSocketTests` pass.
  - [ ] Mac: USB and Wi-Fi sessions connect. Bonjour TXT `wol=` updates (T-128 check). `listening` and `profile` lines are present. (Mac + tablet.)
- Plan hints:
  - Verify Bonjour registration uses `BonjourAdvertiser` on the `bsd` path (SessionServer.swift:227, 1075).
  - `resubmitLast` is also the static-screen keyframe path. Keep it and drop only the `refresh:` branch.
  - Coordinate with M02 (encoder ordering) so both don't edit `HEVCEncoder.swift` concurrently.

### RESET-C — Client: "Varsayılanlara dön" (settings and learned state reset, pairing kept)
- owner: android-client-dev. depends_on: none.
- Wire protocol change: none.
- files: `.../session/Settings.kt`, `.../settings/SettingsCatalog.kt`, `.../MainActivity.kt` (handler), `.../audio/{SharedPrefsOutBufStore,SharedPrefsSafetyStore}.kt`, tests `SettingsCatalogTest.kt` and a new `SettingsResetTest.kt`.
- Goal: one panel action restores defaults: mode, bitrate, transport, audio, pointer speeds, pen trail/dot, clipboard, files and stats. It also clears learned audio state (`matebridge_audio`). It keeps `device_id`, the last endpoint (optional) and `matebridge_pairkeys`.
- Acceptance criteria:
  - [ ] JVM: after reset every getter returns its default, and the pair key store is untouched.
  - [ ] Device: after reset with `audio_buf_bursts` previously grown, `audio_out … buf_source=default`. (Tablet.)
- Plan hints: confirm with a 2-step tap. Log `ev=settings_reset` with no values.

### RESET-H — Host: "Ayarları sıfırla" menu item (stream prefs, USB mode, clipboard; approvals kept)
- owner: mac-host-dev. depends_on: none.
- files: `host-mac/Sources/MateBridgeApp/main.swift`, `host-mac/Sources/MateBridgeHost/Session/UserDefaultsStreamPrefsStore.swift`, a Core helper plus test.
- Goal: restore host defaults without touching approved devices or identity (Keychain).
- Acceptance criteria:
  - [ ] XCTest on the store's `removeAll`.
  - [ ] Mac: after reset the next session uses mode defaults; the approved tablet reconnects without a prompt. (Mac + tablet.)

### IQ-1 — Image-quality bench: RGB-referenced chroma metric plus test patterns (X11)
- owner: mac-host-dev (bench), then user (visual check). depends_on: none.
- Wire protocol change: none.
- files: `host-mac/Sources/MateBridgeHost/Video/SharpnessBench.swift`, `host-mac/Sources/MateBridgeCore/Video/` (pure metric helpers plus tests).
- Goal: measure what 4:2:0 and range/transfer tagging do to thin coloured text and ramps, against an RGB reference rather than pre-subsampled chroma. Add patterns: 1–2 px red/blue/green text on white and black, 0–255 grey ramp, limited/full-range steps, and a moving pattern.
- Acceptance criteria:
  - [ ] XCTest for the metric on synthetic inputs.
  - [ ] Bench prints per-pattern ΔE or CbCr PSNR and luma PSNR at 30/60/80 Mbps. (Mac.)
  - [ ] User views the same patterns on the tablet and notes fringing and range clipping in NOTES. (Tablet.)
- Plan hints: screencap PSNR on the tablet is unusable (NOTES.md:562). A 4:4:4 decode is likely unsupported (PLAN.md:86). Measure first.

### SOAK-1 — D10 soak measurement procedure (8 h, then 1 week) with versioned monitor scripts
- owner: user (runs it), orchestrator (scripts and analysis). depends_on: BUILDID-C, BUILDID-H. Overlaps with the other verifier's smoke/replay/soak item; merge them there.
- Wire protocol change: none.
- files: `tools/soak/` (new: `mbmon.sh` tablet sampler, `macmon.sh` host sampler, `summarize.py`), `docs/NOTES.md` (results).
- Goal: reproducible resource-trend evidence.
  - Sample every 60 s:
    - host RSS (`ps -o rss`), FDs (`lsof -p | wc -l`), threads (`ps -M | wc -l`);
    - tablet PSS (`dumpsys meminfo dev.matebridge.client`), threads grouped by name prefix (`ps -T -p <pid>`: `mb-ctl-read-*`, `mb-video-*`, `mb-audio-*`, `mb-decoder*`), FDs (`run-as … ls /proc/self/fd | wc -l` or `/proc/<pid>/fd` via run-as);
    - codec instances (`dumpsys media.resource_manager`).
  - Count log events: `decoder_give_up`, `detach_slow`, `audio_previous_slow`, `pipeline_retry`, `release_all`, reconnects.
  - No key, text or clipboard content.
- Acceptance criteria:
  - [ ] Each result header has commit SHAs, macOS and HarmonyOS builds, transport, mode, resolution, target and real Hz, bitrate, content and duration.
  - [ ] The 8 h run shows no monotonic thread, FD or PSS growth (slope below an agreed threshold).
  - [ ] Restart-requiring events are counted.
  - [ ] One-week log is summarised.
  - [ ] Anything not run is listed explicitly as "not run".
- Plan hints: the scripts are described in NOTES.md:1060, 1117. Recreate them into the repo rather than scratch.

### TESTSEAM-1 — Enable deterministic lifecycle tests: encoder-ordering seam (host) and codec seam (client)
- owner: mac-host-dev and android-client-dev (two separate cards). depends_on: none. Prerequisite for the M02/M03/H02 cards owned by other verifiers' items.
- Wire protocol change: none.
- files:
  - host: `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`, new `host-mac/Sources/MateBridgeCore/Video/EncoderLifecycle.swift` plus tests;
  - client: `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt`, new `.../video/DecoderBackend.kt` (interface over MediaCodec calls used by `runCodec`) plus a fake in tests.
- Goal: move the ordering and ownership logic (reserve/submit/stop; retire/join/stop/release) behind a small interface, so XCTest and JVM tests can inject barriers and hangs. No behaviour change.
- Acceptance criteria:
  - [ ] A test with a fake backend reproduces today's ordering (documents M02/M03 as-is).
  - [ ] Existing device behaviour is unchanged (smoke: connect, 10 mode changes). (Mac + tablet.)
- Plan hints: keep the interface minimal (configure/start/dequeue/queue/release/stop). Don't redesign; the M03 fix belongs in its own card.

---

## Coverage
- S1: done. S2: done. S3: done.
- P1: done. P2: done. P3: done. P4: done.
- M07 (CI part, keep list, acceptance criteria): done.
- L01: done. L02: done (plus full knob inventory table). L03 (client side): done.
- W4 (Android codec row, Audio row, verdict paragraph): done.
- SE6: done. SE8: done. PF4 (client half): done.
- X11: done. D8: done. D9 (README/build ID/settings reset): done. D10: done.
- F1: done. F3: done. F4: done. F5: done.
- A2 (fixtures/state machines/fuzz bullet): done.
