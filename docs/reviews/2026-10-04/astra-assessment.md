# gpt-6-astra (xhigh) genel değerlendirme — 2026-10-04

Kullanıcı onayıyla (2026-10-04) Codex `gpt-6-astra`, `model_reasoning_effort=xhigh`, salt okunur, `main` @ 0d796e8. Aşağıdaki metin modelin son çıktısıdır (değiştirilmedi). Orkestratörün işlediği maddeler: T-218 (yalnız video kaybında input kapısı), T-219 (decoder kuyruğu nesil sahipliği), T-220 (sunum ölçütü tutarlılığı ve Oyun 120'de 60 fps kadans), PROTOCOL §0x05 "uygulandı mı" kontrolü düzeltildi, 0029 fayda modeli düzeltildi; ekranın medya hatasından ayrılması T-200 (T-166'ya bağlı), encoder teardown süresi ve input tazeliği izlenecek (0025/T-199).

**MateBridge has a sound streaming architecture, but its recovery guarantees are not yet strong enough for an unattended, sole-display system.** The main risks are now at lifecycle boundaries: losing video while retaining input, handing frames between decoder generations, and recovering media without destroying the desktop.

I reviewed the requested documentation and implementation paths. `main` advanced during the review; this assessment includes **`0d796e8`**, including T-213. T-214–T-216 remain plans. No files were modified. The read-only fixture generator check passed; I did not run builds, the full `check.sh`, or device tests.

The architecture’s strengths are substantial: pure Swift/Kotlin policy components, shared protocol fixtures, bounded video queues, authenticated takeover, explicit input release handling, and increasingly disciplined ownership of native codecs. The recent work addresses real defects. The remaining concern is that these individually tested components do not always establish the intended guarantee when connected together.

**The highest-priority correctness and robustness risks are:**

1. **P1 — A video-only failure can leave input enabled indefinitely on a stale image.**

   `VideoClosed` only marks the socket closed and schedules another connection attempt. It does not invalidate video health or release input. Meanwhile, `VideoHealth` detects a stopped decoder or at least three outstanding decoder inputs; a running decoder receiving nothing satisfies neither condition. Input activation depends on that health state.

   Concrete scenario: video was healthy, its TCP connection fails, reconnects fail, and control PONGs continue. The last image remains visible while keyboard and pen events continue reaching the Mac. A half-open video socket is another variant: its reader has no established-stream read timeout.

   Evidence: [SessionMachine.kt:445](client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt:445), [VideoHealth.kt:179](client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt:179), [MainActivity.kt:618](client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:618), [SessionController.kt:884](client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt:884).

   **Fix direction:** a known video disconnection should immediately release and gate input, with recovery requiring fresh video progress. Ambiguous silence needs a bounded liveness check that distinguishes a static desktop from a broken video path. A blanket “no frames for N seconds” timeout would incorrectly fault normal idle operation.

   Also, “healthy” currently means decoder output, not visible presentation: the first-output event precedes buffer release. Decision 0019’s protection against frozen or black video is therefore narrower than its wording suggests.

2. **P1 — A retired decoder can consume a replacement generation’s startup frame.**

   Reconfiguration retires the old generation, resets the shared queue, starts its replacement, and opens delivery for the new configuration. However, the old input loop checks `att.active` only before entering `prefetch`/`awaitNext`; it does not recheck before consuming and submitting the returned frame.

   Concrete interleaving: the old decoder is waiting; reconfiguration resets the queue and admits new frames; the old waiter wakes and takes the new CODEC_CONFIG or keyframe, then submits it to its retiring codec. The replacement waits correctly for codec ownership, but starts without the frame its predecessor consumed.

   Evidence: [VideoRenderer.kt:289](client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:289), [VideoRenderer.kt:538](client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:538), [FrameQueue.kt:189](client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt:189), [CodecGeneration.kt:100](client-android/app/src/main/kotlin/dev/matebridge/client/video/CodecGeneration.kt:100).

   This is a static concurrency finding, not a device reproduction. **Queue consumption needs generation ownership as well as codec ownership.** Merely checking `active` after dequeue and discarding the frame still loses a replacement frame. Add a deterministic barrier test around retirement and queue consumption.

3. **P1 for the sole-display objective — Display lifetime remains coupled to media failure.**

   Parking correctly stops capture and encoding while retaining the display. But the default remains ten seconds, and an unexpected capture/encoder failure still calls ordinary teardown, which invalidates the display before reporting failure.

   Thus a brief network interruption beyond the grace period, or a recoverable codec failure, can become a desktop topology change. The observed black Krita panels during display recreation demonstrate that successful reconnection does not necessarily restore usable application content.

   Evidence: [DisplayLease.swift:12](host-mac/Sources/MateBridgeCore/Video/DisplayLease.swift:12), [VideoPipeline.swift:306](host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:306), [VideoPipeline.swift:318](host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:318), [NOTES.md:1150](docs/NOTES.md:1150).

   Decision 0020 is a useful partial implementation, not completed display-lifetime independence. Complete the parked-display/sleep/Parsec measurements before selecting a longer default, and retain a healthy display across media-only failures.

   Separately, startup-at-login is not crash recovery or pre-login availability. The recovery rehearsal remains unfinished in [T-147](backlog/tasks/T-147-recovery-runbook.md:16). For this product, that is a release requirement.

4. **P2 — T-162 establishes encoder ordering, but teardown still has no liveness bound.**

   The serial submit owner is the right correction. However, `shutdown()` waits until synchronous `CompleteFrames` and `Invalidate` return. Pipeline teardown awaits it; coordinator operations awaiting that pipeline can consequently stop progressing indefinitely.

   Concrete scenario: VideoToolbox hangs during a mode change or disconnect. The ordering remains correct, but subsequent recovery cannot complete.

   Evidence: [HEVCEncoder.swift:464](host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:464), [HEVCEncoder.swift:545](host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:545), [VideoPipeline.swift:308](host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:308).

   This is an unhandled native-hang scenario, not evidence that the hang currently occurs. Recovery should detect and surface it, potentially escalating to controlled process recovery. Starting another codec concurrently with the stuck owner would undermine T-162.

5. **P2 — Bounded input queues do not establish bounded input freshness.**

   `SendQueue` checks age on enqueue, not dequeue. The writer then uses blocking socket writes, while host input-age measurement explicitly never changes injection. Already-buffered TCP input is outside the application queue’s age bound.

   Concrete scenario: a short transport stall accumulates a complete click or key sequence, then delivery resumes before session timeout. The sequence can execute seconds after the user performed it. Host silence release helps held-state safety, but fresh arrivals reset silence tracking and do not prove that those arrivals are fresh actions.

   Evidence: [SendQueue.kt:25](client-android/app/src/main/kotlin/dev/matebridge/client/session/SendQueue.kt:25), [SessionController.kt:818](client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt:818), [InputController.swift:28](host-mac/Sources/MateBridgeHost/Input/InputController.swift:28), [SessionMachine.swift:331](host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift:331).

   Use T-171 measurements to define a freshness policy, preserving owed releases and requiring deliberate rearming after stale input is rejected. Do not independently discard arbitrary key/button edges.

**For smoothness and latency, the evidence supports different bottlenecks for games, drawing, and Wi-Fi.**

| Stage | Assessment |
|---|---|
| Capture/source | The latest game trace contains 50–100 ms source-PTS gaps. No downstream pacer can recover missing content. However, “MateBridge is not responsible” is stronger than the evidence: this localizes the gap before encoding, without distinguishing game rendering, WindowServer, and SCK delivery. [NOTES:1172](docs/NOTES.md:1172) |
| Encode | Approximately 7 ms in the recent game trace. Serial ownership, bounded submissions and the earlier color-tag correction are sensible. This is material latency, but there is no evidence that encoder backlog dominates that USB trace. [NOTES:1162](docs/NOTES.md:1162) |
| USB transport | Host write p99 was 0.36 ms, send queue zero, and significant late arrivals rare. These measurements make transport replacement a low-priority USB optimization. Kernel write completion alone would not prove delivery, but the client-arrival evidence supports the conclusion. |
| Decode | Full-resolution game decoding was around 18–19 ms. Drawing reached 121 received/shown FPS with about 9.3 ms average decoding. Content matters; the earlier inferred universal ~110 FPS decoder ceiling was disproved. [NOTES:1104](docs/NOTES.md:1104), [NOTES:1164](docs/NOTES.md:1164) |
| Pacing | Adaptive pacing improved reported presentation intervals at a measured cost of roughly **5 ms capture-to-release**. That is a defensible smoothness/latency tradeoff, but not proof of perfect cadence. [NOTES:1171](docs/NOTES.md:1171) |
| Panel | Huawei AGP is a hard practical constraint: keyboard/gamepad use stayed at 60 Hz despite the attempted application votes. Sending 120 FPS cannot produce 120 distinct presentations on that panel state. [NOTES:1072](docs/NOTES.md:1072) |
| Wi-Fi | A separate measured problem remains: video bursts inflated control/audio RTT to 60–100 ms. Separate TCP connections and traffic classes did not isolate airtime congestion. [NOTES:979](docs/NOTES.md:979) |

Do not add these numbers into one purported end-to-end latency: they come from different runs and measurement origins. Decoder callbacks and requested presentation timestamps also do not establish physical panel latency.

My improvement ranking, given USB is now the primary transport:

| Rank | Improvement | Expected impact | Effort |
|---|---|---|---|
| 1 | Match game rendering/display rate to sustained panel behavior; investigate source gaps under controlled game load | High smoothness and GPU benefit. RE4 Game60 reduced GPU usage from 90% to 54% while both modes displayed at 60 Hz | Low–medium |
| 2 | Keep adaptive game pacing, but validate it with identical presentation metrics and panel-transition tests | High judder benefit; approximately +5 ms in the observed run | Medium |
| 3 | Measure lower game resolution, especially Game60, with game-render resolution controlled | Potentially substantial decode/composition savings; exact benefit unproven | Medium |
| 4 | Correct video-health and generation-handoff failures | Very high practical usability benefit: prevents freezes and blind input during transitions | Medium |
| 5 | Address Wi-Fi burst congestion through measured bitrate/in-flight control and Ethernet comparison | High on Wi-Fi, little benefit to the demonstrated USB case | Medium–high |
| 6 | Pursue further codec/presentation micro-optimizations | Probably smaller gains than the above; risk of trading throughput or stability for isolated latency wins | High |

The RE4 rate comparison is recorded in [NOTES:1086](docs/NOTES.md:1086). I would not spend the next optimization cycle on another unprivileged AGP workaround, a transport rewrite, or globally reducing drawing resolution.

**My assessment of the specific phase-6 changes is mixed:**

- **0018 pairing trust: materially stronger and structurally sensible.** Explicit pairing initiation, separate pending/trusted storage, fingerprint-checked promotion, and proof before takeover address the earlier trust failures. See [Handshake.kt:125](client-android/app/src/main/kotlin/dev/matebridge/client/security/Handshake.kt:125) and [PairKeyStore.kt:153](client-android/app/src/main/kotlin/dev/matebridge/client/security/PairKeyStore.kt:153). I found no comparable bypass in these reviewed paths. The successful live re-pairing test does not cover disconnected confirmation, stale approvals, key mismatch, or process death throughout the flow.

- **0019 video health: good decoder-fault policy, incomplete usable-video policy.** The first finding is the largest remaining gap. Successful `starting → healthy` transitions during normal mode changes do not test it.

- **0020 parked display and T-162 encoder owner: correct foundations with unfinished failure behavior.** Parking reduces idle work; serial ownership removes an important concurrency hazard. Neither yet guarantees recovery when the underlying platform stops responding.

- **T-208 and the 0014 amendment: plausible improvement, overstated validation.** The initial diagnosis attributed game judder to adaptive-pacer behavior, but the later trace showed game mode bypassed that pacer entirely. The repository correctly records this correction. It demonstrates why production-path validation must precede conclusions from synthetic tests.

  More seriously, `skip_pct` changes meaning across the A/B: with adaptive scheduling it uses scheduler decisions; otherwise it uses `PresentMeter`. Consequently **10% → 0% is not an apples-to-apples presentation measurement**. At cadence two, the new missed-slot branch can produce a three-vsync interval without counting a skip because its comparison is strictly greater than 1.5 times cadence. See [VideoStats.kt:269](client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt:269) and [AdaptivePacer.kt:361](client-android/app/src/main/kotlin/dev/matebridge/client/video/AdaptivePacer.kt:361).

  The reported exact-two-vsync ratio was **88.8% over only 330 filtered intervals**, versus the card’s ≥98% criterion. Better `shown_p95` and user feedback support retaining adaptive mode; they do not establish that the original acceptance criterion passed.

  Also test a 60 FPS game inside **Game120**: [FrameInterval.resolve](client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameInterval.kt:17) does not generally infer content cadence from measured arrivals. A 120-FPS configuration on a 120-Hz panel still resolves to one period even when content arrives every two periods.

- **0029/T-213–T-216: worthwhile experiment, but the benefit model needs correction.** Decision 0029 says existing Game120 scaling only reduces encoding and that the rest of the pipeline remains full resolution. In fact, SCK already outputs `encodedWidthPx/encodedHeightPx`; the documented Game120 stream is already 1848×1214. See [0029:12](docs/decisions/0029-game-display-resolution.md:12) and [ScreenCapture.swift:51](host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift:51).

  Therefore, moving default Game120 to a **1848×1214 1x display does not itself reduce decoder dimensions further**. Its distinct benefits concern display composition, scaling and game-visible modes. Game60 currently streams full resolution, so its potential decode saving is larger. Conversely, a game previously rendering at 1400×920 might render at 1848×1214 after the change, increasing the game’s own rendering load.

  T-213’s optional trailing group preserves old-client bytes and has matching codec changes. T-214 appropriately plans full display-identity checks, suppression of double scaling, persistence and fallback. Keep those invariants.

  One concrete specification defect remains: [PROTOCOL:193](docs/PROTOCOL.md:193) says the client can identify successful application through `width_pt == requested_width`. A requested 1400×920 matches the existing native HiDPI point dimensions even on an old host. Compare the complete pixel-and-point geometry.

  T-216 should compare **the same encoded size with different display topology**, as well as different encoded sizes. Otherwise composition gains and decode gains will be conflated.

**The process has good structure, but hardware acceptance is lagging behind code completion.**

- CI explicitly excludes native SCK, VideoToolbox, CGVirtualDisplay, MediaCodec, AAudio, TCC and actual CGEvent behavior. That is understandable, but means unit-test volume cannot establish appliance reliability. [.github/workflows/check.yml:1](.github/workflows/check.yml:1)
- The October 4 device session is useful, narrow evidence. It explicitly leaves decoder fault injection, key mismatch, USB-only mode and stalled key repeat untested. [NOTES:1157](docs/NOTES.md:1157)
- Prioritize deterministic tests for video-only loss, retirement during input-buffer/queue waits, delayed input replay, and hung teardown. Then run the planned recovery rehearsal, churn tests and eight-hour/overnight soak. These exercise the actual remaining risks.
- Preserve reproducible performance traces with build IDs, actual panel Hz, game settings, encoded dimensions and consistent metrics. Report source gaps, scheduling errors, decoder drops and physical presentation separately.
- The workflow is not consistently enforced: T-213 explicitly records that its plan followed implementation and file scope was approved afterward. CI was still informational according to the latest notes, and a cross-task integration briefly broke `main`. [T-213:56](backlog/tasks/T-213-game-display-protocol.md:56), [NOTES:1140](docs/NOTES.md:1140)

I would make **video-loss input gating, decoder queue ownership, and a rehearsed headless recovery path** the next acceptance gate. Game-display work can proceed, but it should earn its default through measurements that distinguish rendering load, encoded resolution, pacing and the panel’s actual refresh behavior.
tokens used
