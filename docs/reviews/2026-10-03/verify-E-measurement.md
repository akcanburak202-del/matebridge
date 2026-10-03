# Verify E: latency measurement, stats, performance numbers, refresh

Verifier scope: H05 (all sub-points), LM2, LM3, LM5, LM6, LM7, LM8, PF1, PF2, PF3, X12, B1, D5, P5, M07 (measurement bullets only: device smoke package, replay material, soak; the CI part is covered by another agent). HEAD = a30c769. Read-only; no builds.

All paths below are relative to `/home/user/matebridge/`. Client sources are under `client-android/app/src/main/kotlin/dev/matebridge/client/` (abbreviated `client/`). Host sources are under `host-mac/Sources/` (abbreviated `host/`).

## Short answers to the orchestrator's specific questions

**What the client "latency" number measures.** It starts at `VIDEO_FRAME.capture_time_us` (the SCK `CMSampleBuffer` presentation timestamp on the host clock), converted to the client clock with the ClockSync offset. It ends at `System.nanoTime()/1000`, taken when the decoder output thread has just dequeued the output buffer.
- Call chain: `client/video/VideoRenderer.kt:548` `stats.onOutput(info.presentationTimeUs, nowUs())` → `client/video/VideoStats.kt:137-139` `latencyOf?.invoke(cap)` → `client/MainActivity.kt:1165` `clock.latencyUs(cap, SessionController.clockUs())` → `client/stream/ClockSync.kt:29-32`.
- The `nowUs` passed to `onOutput` (elapsedRealtime) is not used for latency. The lambda reads its own `System.nanoTime()` clock, which is the same clock the PONG `now` uses (`client/session/SessionController.kt:325,360-364`).

**Where it is computed relative to pacing and release.** Before both:
- Line 548 records stats, then line 561 calls `adaptivePacer.schedule`.
- Line 573 calls `releaser.submit` (SlotReleaser may hold the buffer until its dispatch deadline).
- `releaseOutputBuffer(idx, renderNs)` happens only in `CodecSink.release`, at `VideoRenderer.kt:499-501`.
- Then come the SurfaceFlinger latch and panel scan-out.
- Frames that are decoded but later discarded (replaced in the SlotReleaser, `Sink.discard`) still contribute a latency sample, so the average includes frames that were never shown.

**Is a negative value clamped to zero?** Yes, per frame: `ClockSync.kt:31` `.coerceAtLeast(0)`. The window value is an arithmetic mean only (`VideoStats.kt:151,182`), with no percentiles. On the wire, "unknown" (null) is sent as 0 (`client/stream/StatsFormat.kt:19`), and the host treats 0 as unknown (`host/MateBridgeCore/Video/StatsSummary.swift:16`). The audio path does the opposite: it keeps negative one-way delays and documents the ±RTT/2 error (`docs/LOGGING.md:115`).

**Which host timestamp goes on the wire, and which one FrameTrace uses.**
- **Wire:** `capture_time_us` = SCK PTS in µs (`host/MateBridgeHost/Video/ScreenCapture.swift:86-92`, passed as `us` → `HEVCEncoder.encode(captureTimeUs:)` → `HEVCEncoder.swift:713` `EncodedVideoFrame(... captureTimeUs: captureTimeUs ...)`). Idle re-submissions carry a synthetic `now + lead` stamp (`HEVCEncoder.swift:358-364`, T-086).
- **Host FrameTrace origin:** `FrameTrace.origin = min(displayTime, PTS, deliveredUs)` (`host/MateBridgeCore/Video/LatencyTrace.swift:64-69`, set at `HEVCEncoder.swift:557-561`). On the device, both SCK stamps lie about 6.6 ms after the callback (NOTES 2026-10-01 ~12:40, line 401), so the origin is in practice the SCK callback time. The tablet number therefore under-reports capture→decode by about 6.6 ms compared with the host's origin.
- **Host CSV (`MATEBRIDGE_LAT_TRACE=1`):** the `capture_us` column is the origin, not the wire PTS (`LatencyTrace.swift:83-88`). Host CSV rows therefore cannot be joined exactly with the client `pace_trace.csv` `capture_us` column, which holds the wire PTS.
- This mismatch is already known: T-072's Handoff *Open questions* (line 50) says to "add this offset to the tablet measurement or use the callback time on the wire (protocol decision, orchestrator)". It was never resolved.

**Does any input sequence or ACK exist?** No.
- KEY, POINTER_REL, POINTER_ABS, SCROLL and PINCH carry `time_us`, and PEN carries `base_time_us` + `dt_us`. These are the client's monotonic clock: `MotionEvent.eventTime*1000`, ms resolution on API 31 (`docs/PROTOCOL.md` §1, §0x10–0x17; `client/input/MotionEventAdapter.kt:118-199`).
- No input message has a sequence number, and no H→C acknowledgement message exists.
- The host never reads any input timestamp: the only `timeUs` references outside the codec are in `host/MateBridgeHost/Input/InjectTest.swift`.
- The host never sends PING. It ignores incoming PONG (`host/MateBridgeCore/Session/SessionMachine.swift:755`), so it has no client→host clock offset. The client does answer a host PING (`client/session/SessionMachine.kt:280`), and the protocol already allows the host to ping (PROTOCOL §6: "Host da aynı aralıkla gönderebilir").

**Does fixing H05 need wire changes?** Mostly no.
- **Rename / re-document:** no byte change. The text of PROTOCOL `0x22 STATS.latency_avg_us` ("Yakalama → ekranda gösterim") and the §6 formula `latency = gösterim_zamanı − …` are wrong today: the code measures decoder output. The host `StatsSummary` comment ("Capture -> shown on the tablet") is wrong too.
- **Pacing / Surface-render / present breakdown:** client-only.
- **p50/p95/p99, negative-value diagnosis, clock uncertainty:** client-only.
- **Frame join key:** `capture_time_us` already identifies a frame on both sides. This is a host-CSV-only fix: log `pts_us`, `frame_seq` and config/session IDs.
- **Host input age:** possible without a wire change. The host sends PING (already allowed) and uses PONG to learn the client→host offset. It then computes `inject_time − (time_us + offset)`.
- **Wire changes are needed only for:**
  - (a) Carrying the host's real capture origin per frame. Option: an appended `VIDEO_FRAME` field after `data`, e.g. `origin_offset_us: i32` = `FrameTrace.origin − capture_time_us`. Trailing fields are allowed by §2 "Uzunluk".
  - (b) A real input ACK. Option: an appended `seq: u32` on PEN/KEY/POINTER_REL/POINTER_ABS/SCROLL/PINCH/PEN_GESTURE/RELEASE_ALL, plus a new H→C control message, e.g. `0x24 INPUT_ACK {last_seq u32, inject_time_us u64}`.
  - (c) Optionally, appended `STATS` fields so the Mac menu can show the new numbers, e.g. `latency_p95_us u32`, `render_latency_avg_us u32`, `clock_rtt_us u32`, `render_cb_missing u32`.
  - Any of these means updating `docs/PROTOCOL.md` and the fixtures (orchestrator only). I recommend deferring (a) to (c) until the no-wire-change items are done and the 6.6 ms lead has been shown to vary.

## Verdicts

### H05 — Latency metric doesn't validate the product claim
- **Verdict:** CONFIRMED (all four evidence sub-points). The fix proposals are sound but partly already exist.
- **Evidence:**
  - *Computed at onOutput:* `VideoRenderer.kt:546-549` records stats before `schedule` (559-561), `releaser.submit` (573) and `releaseOutputBuffer` (`CodecSink`, 497-511). The value excludes AdaptivePacer, SlotReleaser hold/shift, SurfaceFlinger latch, panel scan-out and the entire input path.
  - *Size of the missing pacing part, measured by the project itself:* ready→slot p50 is **17.1 ms** (120 Hz, trace2, NOTES line 389) and **13.1 ms** (trace7, NOTES line 431). An earlier 60 Hz lock measured 42.5 ms (NOTES line 385). The pacing stage alone is therefore larger than the whole "10.6 ms" headline.
  - *Host origin vs wire stamp:* see the answers above. PTS leads the callback by +6.6 ms (NOTES line 401). The host CSV column `capture_us` is the origin, not the PTS (`LatencyTrace.swift:83-88`).
  - *"Shown/rendered" is not the panel:*
    - `rendered` is incremented when `releaseOutputBuffer` is called (`VideoRenderer.kt:501,509`), yet it is logged as `shown=` (`MainActivity.kt:1459`) and used for the overlay "FPS" (`StatsFormat.kt:26`) and the host fps (`StatsSummary.swift:14`).
    - The `shown_*` gap fields come from `OnFrameRenderedListener` (`VideoRenderer.kt:388-397`). The project itself documents that this is "codec render time, not SurfaceFlinger's real present time" (T-016 Handoff line 45; `VideoStats.kt:100,24`).
  - *Doc drift:* PROTOCOL §0x22 and §6 both say "→ ekranda gösterim" (to on-screen display). `VideoStats.kt:12` correctly says "capture-to-output". Host `StatsSummary.swift:7` says "Capture -> shown on the tablet". The overlay label is "Gecikme" (`StatsFormat.kt:31`), and the Mac menu shows it as plain "· N ms".
- **Corrections:**
  - The review misses that much of the "report separately" fix already exists in logs:
    - Decode p50/p95/p99 (`dec_*`, `VideoStats.kt:26,158`).
    - Pacer-added delay `pace_add_ms`, which is relative to the earliest vsync, so it is not the full ready→slot time.
    - Arrival/ready/shown gap p50/p95/p99, `clock_offset_us` and `rtt_us` (`MainActivity.kt:1465-1477`).
    - Host per-stage p50/p95/p99/max (`ev=latency`, T-070/T-072).
    - A per-frame pace trace (`--ez pace_trace true`, T-069/T-073/T-077) with capture, ready, slot, release and render columns.
  - A frame join key already exists de facto: `capture_time_us` equals the client trace `capture_us` and the host `FrameTrace.ptsUs`. Only the host CSV writes the wrong column.
  - The app's own A/V-sync estimate already composes `toOutput + paceAdd + 1 period` (`client/audio/AvSync.kt:19-26`), so the code knows the number is partial.
  - "Separate presentation PTS on the wire" is not needed: the client computes its own slot and render time.
- **Severity opinion:** Agree it is High as a decision-quality and acceptance problem: the user-facing "Gecikme 11 ms" and the Mac menu number are mislabelled by roughly 2–4×. It is not a runtime correctness defect. Most of the fix is small, client-only and JVM-testable.

### LM2 — Client "latency" = clock-aligned capture timestamp → decode output; computed before pacing and release
- **Verdict:** CONFIRMED.
- **Evidence:** `VideoRenderer.kt:548` → `VideoStats.kt:128-140` → `MainActivity.kt:1165` → `ClockSync.kt:29-32`. Pacing is at 559-561 and release at 573 / 499-509.
- **Corrections:** The review says "capture timestamp ≠ physical pixel creation", which is right but understated. The wire PTS lies about 6.6 ms *after* the SCK callback (NOTES line 401), so the number misses even the host's own capture→callback stage. It also averages frames that are decoded but later discarded by the SlotReleaser.
- **Severity opinion:** Part of H05; Medium on its own (labelling and measurement).

### LM3 — True input-to-photon is not measured by any counter
- **Verdict:** CONFIRMED.
- **Evidence:**
  - No code measures input → display.
  - The host ignores input `time_us` (grep shows no consumer outside `InjectTest.swift`).
  - No ACK exists.
  - PLAN §Faz 2 line 143, "[ ] Kalem gecikmesi ölçülür" (measure pen latency), is still unchecked.
  - PLAN line 147 closes Phase 2 with "uçtan uca kalem gecikmesi … kullanım sırasında bakılacak" (end-to-end pen latency to be checked during use).
  - T-025 line 31 (slow-motion camera idea) was never executed.
  - NOTES contains no optical measurement.
- **Corrections:** None.
- **Severity opinion:** Agree it is High as missing evidence for the core differentiator (pen). It needs the user and hardware, not code.

### LM5 — ClockSync midpoint, Wi-Fi asymmetry, clamping hides error
- **Verdict:** CONFIRMED.
- **Evidence:**
  - `ClockSync.kt:14-24`: offset = `responder − (echo + rtt/2)`, taking the lowest-RTT sample of the last 8 (window ≈ 4 s at 500 ms pings). Line 31 clamps the result to ≥ 0.
  - The PONG `now` is taken in `SessionController.dispatch` after decryption and event dispatch, and the host's `responder_time_us` is taken on the session queue (`host/MateBridgeHost/Session/SessionServer.swift:1733`). Processing time therefore also enters the RTT, but the error stays bounded by RTT/2.
- **Corrections:**
  - The review doesn't say which way the bias goes. Under Wi-Fi load the downlink carries the video, so the PONG (H→C) leg is slower than the PING leg. The offset is then under-estimated by `(down − up)/2`, and the latency is **under-reported** by the same amount.
  - Measured Wi-Fi RTT under load is 25–28 ms, p95 up to 50 ms (NOTES lines 588-592, 632-639), so the uncertainty is up to about ±12–14 ms. On USB it is about ±2.3 ms (RTT 4.6 ms).
  - `rtt_us` (best RTT) is already logged next to `latency_us` (`MainActivity.kt:1466`), so the bound can be derived from the logs. It is not shown in the overlay or in STATS.
- **Severity opinion:** Medium. It matters for any Wi-Fi latency claim and is irrelevant for pacing: AdaptivePacer is offset-free, see `AdaptivePacer.kt:8-9`.

### LM6 — AdaptivePacer pad bounds; SlotReleaser shift; not a hard deadline
- **Verdict:** PARTIALLY CORRECT.
- **Evidence:**
  - The slack `D` cap depends on the case (`AdaptivePacer.kt:203-206`):
    - Surplus content (fi < 0.75 P): `≤ P + 0.5 ms`.
    - Lockable: `≤ P`.
    - Otherwise: `≤ 1.5 P`.
  - The final slot bound is separate:
    - Unlocked path: `earliest + P` (`:225-226`).
    - Locked path: `latencyBound = P + min(j, P)/2` after earliest (`:258`, `:308-309`).
  - `earliest` itself is the first vsync ≥ `now + deadline`, default 6 ms (`AdaptivePacer.kt:216`; `FramePacer.kt:35`, T-071).
  - SlotReleaser moves a frame whose slot ≤ an already released slot to `released + P` (`SlotReleaser.kt:43-52`, T-065). This bypasses the pacer bound by up to one more period.
  - The release itself is only a request: `releaseOutputBuffer(idx, renderNs)`, which SurfaceFlinger may latch later.
- **Corrections:**
  - The review merges the D cap and the slot bound, and it omits the surplus case.
  - The worst-case ready→slot is about `deadline + P (grid rounding) + 1.5 P (+ P releaser shift)`: ≈ 27–35 ms at 120 Hz and ≈ 48–64 ms at 60 Hz. This is my arithmetic from the code, not a measurement.
  - "Not a hard deadline" is correct.
- **Severity opinion:** Informational. It supports H05: pacing is the largest unreported stage.

### LM7 — Example: 300 kB over 30 Mbit/s ≈ 80 ms
- **Verdict:** CONFIRMED as arithmetic (2.4 Mbit / 30 Mbit/s = 80 ms); not measured on the device.
- **Evidence:**
  - The real periodic keyframe is ~432 KB (NOTES line 407).
  - Wi-Fi capacity was capped at ~27 Mbps before T-091; after BSD sockets it carries ~60 Mbps without retransmits (NOTES lines 595, 642).
  - So a 432 KB IDR is about 58 ms at 60 Mbps, or about 128 ms if the link drops to 27 Mbps. The illustration holds.
  - Related, already measured: `kilit ekranı yükü` (lock-screen load) ~200 KB/frame at 60 Mbps gave a 52–55 ms Wi-Fi latency median (NOTES line 639).
- **Corrections:** The illustrative example is consistent with the repo's numbers. Its "30 Mbit/s" is outdated for the current BSD path, but it is realistic for a congested link.
- **Severity opinion:** Informational.

### LM8 — Proposal: frame ID + generation join, percentiles, oldest-work age, input seq + ACK, OnFrameRendered caveats, optical 240 fps test
- **Verdict:** Proposal. Valid; partly ALREADY ADDRESSED.
- **Evidence:**
  - Percentiles already exist for decode, gaps and host stages. They are missing only for the client latency itself (mean only).
  - The per-frame client trace exists (T-069/T-073/T-077). The host CSV exists (T-070), but with the wrong join column.
  - The OnFrameRendered caveat is already documented and handled: `VideoStats.kt:24,100` and the PresentMeter note "overestimates". The tablet is API 31 (NOTES line 14), so `FrameTimeline` (API 33) and Java `SurfaceControl.Transaction.setBuffer` are unavailable. NDK `ASurfaceTransactionStats_getPresentFenceFd` exists on the device but was dropped in T-084 for latency reasons; NOTES line 508 says it "could later serve as a probe".
  - Input seq and ACK do not exist (see above).
  - Optical measurement is not done (LM3).
- **Corrections:** "Oldest-work age": the client has `in_codec_p95` and queue fields; the host has `queue` stage percentiles. An explicit "age of oldest pending item" gauge does not exist on either side. Session/config generation: the client logs `MbLog.gen`, and the host has `session_id`/`config_id`, but the traces carry neither.
- **Severity opinion:** Agree. Do the cheap no-wire parts first.

### PF1 — Oct 3 USB drawing figures
- **Verdict:** CONFIRMED (numbers exact), with small corrections.
- **Evidence:** NOTES lines 1100-1113:
  - 60 s per scale, only seconds with ≥ 100 frames received.
  - 100% row: 121/121 received/shown, 2 dropped, decode avg median 9.3 ms, latency median 10.6 ms.
  - "Host kodlama 120 fps, `enc_ms` p50 ~7,2 ms" (host encoding).
- **Corrections:**
  - "Alınan/gösterilen" means **received**/shown, not "captured"/shown.
  - "Shown" here is the release count (`shown=${s.rendered}`, `MainActivity.kt:1459`), not even the codec render callback, let alone panel presentation.
  - The trials were single runs per scale ("tek tur", line 1106), filtered to dense seconds. That is the cherry-pick pattern M07 warns about.
  - The run used `Çizim` mode with `draw_scale`. At 100% this is the same 120 fps / full-scale configuration as the current default Akıcı, so it is still representative.
  - The 10.6 ms is the LM2 metric (≈ +6.6 ms PTS lead and +13–17 ms pacing are not included).
- **Severity opinion:** Agree with the review's framing: these are project-internal software numbers.

### PF2 — Decode > 8.33 ms does not preclude 120 fps; no 144 Hz e2e evidence
- **Verdict:** CONFIRMED; the 144 Hz half is moot.
- **Evidence:**
  - Decode latency is `queueInputBuffer`→output per frame (`VideoStats.kt:131-135`). Several frames are in flight (`maxInFlight`, `gauge` / `in_codec_p95`), so throughput ≠ 1/latency.
  - The device shows a 9.3 ms average decode at 121 fps with `overflows=0` (NOTES line 1104).
  - For 144 Hz: NOTES line 289 says that under the Dinamik/Yüksek settings "144 Hz video uygulamasına hiç verilmiyor" (144 Hz is never given to the video app), and the "Performans 144" mode was removed.
- **Corrections:** The review omits that 144 Hz is not obtainable for this app on this device, and that the product no longer offers it.
- **Severity opinion:** Low.

### PF3 — Huawei panel policy: 120 Hz with pen/mouse/touchpad, 60 Hz with keyboard/gamepad; animation and reflection experiments failed, default off
- **Verdict:** CONFIRMED.
- **Evidence:**
  - NOTES line 291 (T-051): touchpad/mouse → 120 Hz, pen → 120 Hz (119–121 fps), back to 60 Hz after motion.
  - NOTES line 1076: touch, BT mouse and trackpad raise the panel to 120 Hz; keyboard and gamepad do not.
  - NOTES lines 1071-1077 (T-140): the animation and reflection paths kept the panel 100% at 60 Hz.
  - T-140 card lines 28, 62: `--ei rvote N`, default 0 (off), "Kod varsayılan kapalı kalıyor" (code stays default-off).
  - NOTES lines 1062-1069: AGP `JudgeFinalLcdFps` idle rule; strategy `60120`.
- **Corrections:**
  - The review's cited line range is fine.
  - Measurement consequence the review misses: on this device the 60 vs 120 Hz split is driven by input type, so it is confounded with it. An optical "60 Hz" baseline needs keyboard-driven content; any pen test runs at 120 Hz.
- **Severity opinion:** Informational.

### X12 — Target Hz vs real panel tracked separately; content types separated; unsupported target reported
- **Verdict:** PARTIALLY CORRECT (partly addressed).
- **Evidence:**
  - Per-window log: `hz=` and `display_hz=` are both `windowManager.defaultDisplay.refreshRate` (`MainActivity.kt:1295,1467-1468`), a duplicate under two names.
  - The real cadence is measured separately as `vsync_ms_p50` (Choreographer gaps) and `vsync_period_us`.
  - The target is logged only on change: `display_mode requested_hz=… current_hz=` at `MainActivity.kt:1310` and `display_rate hz=` at `:1230`.
  - The reported refresh rate and SurfaceFlinger's fps can disagree with AGP's final LCD fps (NOTES line 272: `sfFps 120` while `final lcd fps: 60`). Even Choreographer is only a proxy.
  - Content type is not tagged in the stats lines (the mode is in the overlay only).
  - Unsupported 144 Hz was removed rather than reported (NOTES line 289).
- **Corrections:** The logs already partly separate target from real cadence. What's missing is the target in the per-window line, a de-duplicated `hz`/`display_hz`, and a "requested X, got Y" warning.
- **Severity opinion:** Low–Medium, as an acceptance-matrix item.

### B1 — Proposed starting budgets (USB pen input-to-photon p95 < 45 ms, Wi-Fi p95 70 ms, …)
- **Verdict:** Proposal; NOT VERIFIABLE IN CODE (needs the device). The budget is likely too tight for the current pipeline.
- **Evidence (software-visible sum, USB, 120 Hz, medians, my estimate):**

  | Stage | Estimate | Source |
  |---|---|---|
  | Input transit | ~2 ms | USB RTT 4.6 ms, NOTES line 590 |
  | Mac app + WindowServer + SCK composition | ≥ 1 frame (8.3 ms), unknown | not measured |
  | Callback→decode output | ≈ 17 ms | 10.6 + 6.6 |
  | Ready→slot | 13–17 ms | NOTES lines 389, 431 |
  | Latch / scan-out | ~4–8 ms | estimate |
  | **Total p50** | **≈ 45–55 ms** | before any p95 tail |

- **Corrections:** Set the budgets after the optical baseline (LM3) and record them in a decision. Per PF3, a 60 Hz budget must be tested with keyboard input, not pen.
- **Severity opinion:** Agree that budgets are needed. The numbers should not be adopted before a baseline exists.

### D5 — Measurement as part of the product (stage traces joined by frame/session ID, rename, Surface + input ACK, optical baseline USB 60/120, versioned analysis scripts)
- **Verdict:** Proposal. Valid; partly ALREADY ADDRESSED.
- **Evidence:**
  - The pacing replay tools are versioned in the repo: `tools/pacing/` (`sim.py`, `gaps.py`, a 3000-frame `trace7_120hz_excerpt.csv`), used by `SparseFrameNoHoldTest.traceReplayOldVersusNew` and `ConstantPlayoutPacerTest`.
  - The newer power/fps tools (`mbmon.sh`, `an.py`, `macmon.sh`, `macan.py`) exist only in scratch (NOTES lines 1069, 1117).
  - The join key exists (`capture_time_us`), but the host CSV logs the origin instead.
- **Corrections:** Not a greenfield effort. The work is fixing the labels and the join, plus adding three or four distributions.
- **Severity opinion:** Agree it belongs in the development order right after the safety items.

### P5 — Old ~110 fps decoder-ceiling estimate disproven by the later 120 fps experiment
- **Verdict:** CONFIRMED.
- **Evidence:**
  - NOTES line 1066: estimate from `media_codecs_performance.xml`, "2800×1840 ≈ 110 fps".
  - NOTES line 1104: "bugünkü yapılandırmada **yanlış**" (wrong in today's configuration); 120 fps at full resolution with `overflows=0`; the old 100–110 fps measurement predates T-052.
  - Decision 0017 (Çizim) was withdrawn (commit 19bbbda).
- **Corrections:** None.
- **Severity opinion:** Informational.

### M07 (measurement bullets only) — device smoke package, replay material, soak
- **Verdict:** PARTIALLY CORRECT.
- **Evidence:**
  - *Replay material:* the review says none is versioned. That is wrong for pacing: `tools/pacing/` holds an anonymised timing-only trace plus scripts and JVM replay tests (see D5).
  - Missing replay material: input (pen/pointer) traces, network-condition definitions, and the power/refresh tools (scratch only, NOTES lines 1069, 1117).
  - *Smoke package:* no one-command script. `scripts/` holds only `board.sh`, `bundle-host.sh`, `check.sh`, `codex-review.sh`, `install-apk.sh`, `make-mac-icon.swift` and `usb-mode.sh`.
  - Build identity is weak: `versionName = "0.1"` (`client-android/app/build.gradle.kts:16`). This belongs to L01, another agent.
  - *Soak:* only a 30-minute run (NOTES 2026-09-30, lines 149-155) on an old build: RSS 64 MB flat, PSS 68–73 MB, 0 disconnects. There is no 8 h or one-week evidence. PLAN line 173 defines "a week of daily use" as the exit criterion.
- **Corrections:** Replay material partly exists.
- **Severity opinion:** Medium, as the review says.

## Additional issues found

1. **VideoStats per-frame maps can silently drop decode and latency samples after a reconnect** (inferred from code; not reproduced; JVM-testable).
   - **Where:** `VideoStats.kt:64-65,116-121`.
   - **Mechanism:**
     - `inputTimes` and `captureTimes` are keyed by `frame_seq`.
     - When a map exceeds 64 entries, the code evicts `keys.min()`.
     - Entries are removed only by a matching `onOutput`.
     - Frames lost in a codec teardown, and codec-config inputs, leave stale entries.
     - `VideoStats` lives as long as the renderer, which is created once per activity (`VideoRenderer.kt:67`, `MainActivity.kt:1151,1166`). Nothing clears these maps.
     - `frame_seq` restarts at 0 on every video connection (PROTOCOL §0x41).
   - **Effect:** once roughly 60 stale high-numbered keys have built up across teardowns, each new low-numbered entry is the minimum and is evicted at once. `decode_avg_us` then reads 0 and `latency` reads null/"?" for the new stream until its `frame_seq` passes the stale keys, which can take minutes. The A/V target input `AvSync.videoLatencyUs(lat…)` (`MainActivity.kt:1393`) becomes null during that time.
   - **Fix:** clear both maps at stream and codec boundaries (`closeWindow`, `runCodec` start), or key them by (codec generation, seq).

2. **Host CSV is not joinable with the client trace.** `FrameTrace.csvHeader` writes `capture_us` = origin (`LatencyTrace.swift:83-88`), while the wire and the client trace use the PTS. The CSV also has no `frame_seq`, `config_id` or `session_id` column. `frame_seq` is assigned in `VideoSender` (`host/MateBridgeCore/Video/VideoSender.swift:18,99`).

3. **The protocol and host docs say the metric is "to display".** PROTOCOL §0x22 `latency_avg_us` and §6 say "gösterim" (display), and the host `StatsSummary.swift:7` comment says "Capture -> shown on the tablet". The code measures decoder output. This is doc drift on a wire field's meaning.

4. **`shown=` is the release count.** In `MB/decoder ev=stats`, `shown=` is the release count (`MainActivity.kt:1459`), the same counter as the overlay "FPS" and the host's `fps`. The project's own device notes report "gösterilen" (shown) from it. It should be renamed to `released=`, or `shown` should be fed from the frame-rendered callback count, with a `render_cb_missing` difference.

5. **Duplicate refresh fields.** `hz=` and `display_hz=` are the same value (`MainActivity.kt:1467-1468`), while the requested target is missing from the per-window line (X12).

6. **Latency sample selection.** The latency average includes decoded frames that the SlotReleaser later discards (`VideoStats.onOutput` runs for every decoded frame), so it is not "latency of shown frames".

## Proposed work items

### W1 (from H05/LM2/LM5) — Client: break latency into stages with distributions, stop clamping, fix the per-frame maps
- **owner:** android-client-dev
- **depends_on:** []
- **decision record:** no.
- **wire change:** none. The STATS byte layout is unchanged, and `latency_avg_us` keeps its current value.
- **files:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoStats.kt`
  - `.../video/VideoRenderer.kt`
  - `.../video/IntervalHistogram.kt` (if a signed variant is needed)
  - `.../stream/ClockSync.kt`
  - `.../stream/StatsFormat.kt`
  - `.../MainActivity.kt` (only `statsTick`, `writeStatsLog`, the `latencyOf` wiring)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/`
  - `docs/LOGGING.md` (the client video stats section)
- **Goal:** Make the tablet's numbers say what they measure. Report capture-stamp→decode-output, ready→planned-slot, capture-stamp→release and capture-stamp→codec-render-callback as p50/p95/p99/max per log window. Report negative clock-corrected samples as a count instead of hiding them. Show the clock uncertainty (best RTT / 2).
- **Out of scope:** Wire changes; host; optical measurement; the SurfaceControl present fence.
- **Acceptance criteria:**
  - [ ] New `MB/render ev=stats` fields (JVM: StatsFormat/VideoStats tests): `cap_dec_p50/p95/p99/max_us` (the existing metric, renamed in the log; keep `latency_us=` as a deprecated alias for one release); `ready_slot_p50/p95/p99_us` (slotNs − readyNs from the pacer decision); `cap_rel_*` (capture → `releaseOutputBuffer` call); `cap_cb_*` (capture → `OnFrameRenderedListener` nanoTime, codec-render mode only); `render_cb_missing` (releases without a callback in the window); `lat_neg` (count of negative raw samples); `clock_unc_us` (= best RTT / 2).
  - [ ] The raw latency is signed internally. `ClockSync.latencyUs` gets a signed variant, and the clamp applies only where a u32 is written (STATS).
  - [ ] Only frames that are actually released are counted in `cap_rel`/`cap_cb`. Discarded frames are excluded and counted separately.
  - [ ] The overlay label "Gecikme" becomes e.g. "Yak→çöz", and an overlay line shows `ready→slot p50` and `±clock`.
  - [ ] VideoStats `inputTimes`/`captureTimes` are cleared on a stream or codec boundary (or keyed by codec generation). JVM test: 70 stale high keys, then a new stream starting at seq 0 still yields decode and latency samples.
  - [ ] `MB/decoder ev=stats` `shown=` is renamed to `released=` (a `shown=` alias may stay for one release), and `docs/LOGGING.md` is updated.
  - [ ] `./scripts/check.sh` passes.
  - [ ] Device (orchestrator, one at a time): on USB 120 Hz while drawing, the new fields appear; `ready_slot_p50` is about 13–17 ms (consistent with NOTES lines 389, 431); `lat_neg` is 0 on USB.
- **Plan hints:**
  - `VideoRenderer.drainOutput` (546-573) has `readyNs` and `d.slotNs`.
  - `CodecSink.release` (499) needs the pts, so pass a pts→captureUs lookup or tag through `SlotReleaser.Sink.release`.
  - Use `captureByPts` / `readyByPts`, which already exist.
  - The OnFrameRendered handler runs on the main looper; keep the VideoStats methods `@Synchronized`.
  - The PTS lead (~6.6 ms) is not corrected here (see W4).

### W2 (from H05/LM8/D5) — Host: make the latency trace joinable and fix the labels
- **owner:** mac-host-dev
- **depends_on:** []
- **decision record:** no.
- **wire change:** none.
- **files:**
  - `host-mac/Sources/MateBridgeCore/Video/LatencyTrace.swift`
  - `host-mac/Sources/MateBridgeHost/Video/LatencyCsv.swift`
  - `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift` (trace fields only)
  - `host-mac/Sources/MateBridgeCore/Video/VideoSender.swift` (record seq into the trace only)
  - `host-mac/Sources/MateBridgeCore/Video/StatsSummary.swift`
  - `host-mac/Tests/`
  - `docs/LOGGING.md` (host latency section)
- **Goal:** Each host trace row should be joinable exactly with the tablet's `pace_trace.csv` row of the same frame. Labels should stop calling the tablet number "shown".
- **Out of scope:** Changing the wire `capture_time_us` value; input timing.
- **Acceptance criteria:**
  - [ ] `latency.csv` appends the columns `pts_us` (the exact wire `capture_time_us`), `display_us`, `frame_seq`, `config_id` and `session_id`. Existing columns keep their order. XCTest checks the header and a line.
  - [ ] `ev=latency` also logs `cap_to_sent` measured from the PTS (signed), so host and tablet totals can be put on one origin when needed.
  - [ ] The `StatsSummary` comment and menu text read e.g. "tablet capture→decode N ms"; `logFields` key `latency_ms` → `cap_dec_ms` (alias allowed).
  - [ ] `./scripts/check.sh` passes.
  - [ ] Device: one 60 s USB run with `MATEBRIDGE_LAT_TRACE=1` plus the client `pace_trace` joins on `pts_us == capture_us` for ≥ 99% of frames.
- **Plan hints:** `frame_seq` is known only in `VideoSender` (line 99). Record it where the trace's `writeStartUs` is set. Resubmitted idle frames have synthetic stamps; mark them with a `resubmit` column.

### W3 (from LM3/LM8/H05 "input ACK") — Host: measure input age at injection without a wire change
- **owner:** mac-host-dev
- **depends_on:** []
- **decision record:** a short one is recommended, because the host starts sending PINGs. Draft: *"The host sends PING every 500 ms on the control connection (already permitted by PROTOCOL §6) and handles PONG to estimate the client→host clock offset with the same min-RTT rule as the client. It uses the offset only for diagnostics: per-message input age = injection time − (client `time_us`/`base_time_us + dt_us` + offset), logged as p50/p95/p99/max per window and per class (pen/pointer/key/scroll). No behaviour depends on it, so the watchdog and input safety are unchanged. Keycodes and characters are never logged."*
- **wire change:** none. PING/PONG already exist and the client already answers PING (`client/session/SessionMachine.kt:280`). Ask the orchestrator to confirm that PROTOCOL §6 needs at most a clarifying sentence.
- **files:**
  - `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift` (PONG handling, PING tick)
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift` (timer, routing)
  - `host-mac/Sources/MateBridgeCore/Input/` (a new pure `InputAgeMeter`)
  - `host-mac/Sources/MateBridgeHost/Input/InputController.swift` (call site at injection)
  - `host-mac/Tests/`
  - `docs/LOGGING.md`
- **Goal:** Make the input path's software latency visible, including Wi-Fi bunching (M04 context) and stalls. This gives the "input ACK" information on the host side without a protocol change.
- **Out of scope:** Using timestamps to schedule injection (M04); a client-visible ACK; changing the watchdog.
- **Acceptance criteria:**
  - [ ] XCTest: offset estimator (min RTT, bogus echo ignored); age meter histogram; a PONG from a non-current connection is ignored; no PING is sent before ACCEPTED.
  - [ ] `ev=input_age` per 10 s window: counts and p50/p95/p99/max per class, plus `clock_unc_us`. No key or char data.
  - [ ] The Codex review passes (an input-path change).
  - [ ] Device: USB pen p50 is a few ms; Wi-Fi shows a larger p95 (record the numbers in NOTES).
- **Plan hints:**
  - Android event times have ms resolution (`eventTime*1000`), so ±1 ms quantisation is expected.
  - Client `time_us` (uptime) and PONG `responder_time_us` (`System.nanoTime`) share the CLOCK_MONOTONIC base (`client/input/Model.kt:10`).
  - The host's `responder now` = `HostClock.nowUs()`.

### W4 (from H05 "real capture origin on wire") — Orchestrator: decide on the 6.6 ms PTS lead
- **owner:** orchestrator
- **depends_on:** [W2] (needs `pts_vs_deliv` variance data from the joined traces)
- **decision record:** yes. Draft: *"The wire `VIDEO_FRAME.capture_time_us` stays the SCK PTS, because the tablet pacer relies on its regular cadence (`AdaptivePacer.kt:8-9`). The host's trace origin (SCK callback / displayTime) lies ~6.6 ms before it (NOTES 2026-10-01 ~12:40). Option A, chosen if `pts_vs_deliv` p99−p1 < 1 ms: no wire change; tablet reports are named 'capture-stamp→…', and analysis adds the host-logged lead. Option B: append `origin_offset_us: i32` (origin − capture_time_us, ≤ 0) after `data` in `VIDEO_FRAME` (allowed by §2), add a golden vector, and the client reports origin→decode as well."*
- **wire change:** only under option B: `VIDEO_FRAME` gains the appended field `origin_offset_us i32`; `docs/PROTOCOL.md` §0x41 and `protocol/fixtures/` (`video_frame*`) must be updated.
- **files:** `docs/decisions/`, `docs/PROTOCOL.md`, `protocol/fixtures/` (option B only).
- **Acceptance criteria:** [ ] the decision is recorded; [ ] the PROTOCOL §0x22 and §6 text is corrected to "decoder output" regardless of the option chosen (doc-only, no byte change).

### W5 (from LM3/B1/D5/PF3) — User measurement: optical input-to-photon baseline
- **owner:** user (procedure written and results recorded by the orchestrator)
- **depends_on:** [W1] (so the software numbers are logged in the same run). W3 is optional.
- **decision record:** after the results: "latency budgets" (B1), with numbers taken from the baseline.
- **wire change:** none.
- **files:** `docs/NOTES.md`, `tools/measure/optical/README.md` (procedure plus a frame-counting script, if the orchestrator adds one).
- **Goal:** Get the first physical end-to-end numbers and explain the residual against the software stages.
- **Procedure:**
  1. Use a phone at 240 fps (4.17 ms per frame), on a tripod, framing both the pen tip and the tablet screen. Turn off Krita brush smoothing ("Yok"), or use a minimal Mac canvas.
  2. **USB, 120 Hz (pen):** 30 discrete taps or short strokes. Measure from the frame where the tip touches to the first frame where the mark appears.
  3. **USB, 60 Hz:** use the keyboard, because per PF3 the pen forces 120 Hz. Press a key on the tablet keyboard into a Mac text field, and measure from the key-down frame to the glyph appearing. Confirm 60 Hz with `vsync_ms_p50≈16.7`.
  4. **Wi-Fi (BSD, Akıcı):** repeat steps 2 and 3.
  5. Run each condition ≥ 3 times on different days. Report p50/p95/max and the count of > 100 ms outliers, plus commit, mode, bitrate, transport and panel Hz. Keep the client and host stats logs from the same minute.
  6. **Residual:** optical − (`cap_cb` or `cap_rel` + 6.6 ms lead + `input_age`). The remainder is the Mac app, WindowServer, SCK composition and panel time.
- **Acceptance criteria:** [ ] a NOTES entry with the table; [ ] the budget decision drafted; [ ] no raw video committed (only the frame-index CSV).

### W6 (from M07 measurement bullets) — Version the device measurement kit and add a smoke command
- **owner:** orchestrator (scripts/tools; device runs one at a time)
- **depends_on:** [] (L01 build identity helps; another agent covers it)
- **decision record:** no (no new dependencies; bash and python3 stdlib only).
- **wire change:** none.
- **files:** `tools/measure/` (new: `mbmon.sh`, `an.py`, `macmon.sh`, `macan.py` rewritten from the NOTES recipes, plus a README), `scripts/device-smoke.sh` (new), `docs/WORKFLOW.md` (one paragraph).
- **Goal:** Make the performance and power numbers reproducible: the same tools in git, and one command that captures build/codec/panel/mode/transport plus a 60 s stats window.
- **Out of scope:** CI (another agent); instrumentation tests.
- **Acceptance criteria:**
  - [ ] `scripts/device-smoke.sh` prints: git SHA (host and APK, once available); host OS; tablet build (`getprop ro.build.display.id`); codec name (`MB/decoder ev=codec` / `logOutputFormat`); `stream_config`; panel Hz and `vsync_ms_p50`; transport. It collects 60 s of `MB/render ev=stats` / `ev=latency` lines filtered to numeric fields only (no clipboard, key or text lines), and writes a small summary (p50/p95 of the key fields) to stdout.
  - [ ] A soak procedure is documented: 8 h of real work with 1/min sampling of host RSS, `lsof -p` count and thread count, and of client PSS, `/proc/<pid>/fd` count, thread count and `dumpsys media.codec` instance count, plus reconnect and release counts from the logs. Then one week, with daily summary lines in NOTES.
  - [ ] Each recorded result includes commit, OS versions, codec, topology, resolution, target and real Hz, bitrate, content, duration and run count (≥ 3).

### W7 (from X12) — Client: log the target and real refresh separately
- **owner:** android-client-dev
- **depends_on:** [] (can merge into W1 if it fits in one context)
- **wire change:** none.
- **files:** `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (the stats log line and `applyRefreshRate` logging only), `client-android/app/src/test/`, `docs/LOGGING.md`.
- **Goal:** Make the gap between the panel rate the client asked for and the rate it actually runs at visible in every log window.
- **Acceptance criteria:**
  - [ ] The `MB/render ev=stats` line carries `target_hz=` (`FrameRatePolicy.modeTargetHz`), `display_hz=` (`Display.refreshRate`), `vsync_ms_p50=` (measured) and `stream_mode=`. Duplicate `hz=` is removed or kept only as an alias.
  - [ ] When `target_hz` differs from the measured Hz for more than 5 s while streaming, one `ev=refresh_mismatch` info line is logged (rate-limited).
  - [ ] `./scripts/check.sh` passes.

## Coverage

| Claim | Verdict entry |
|---|---|
| H05 | yes (all sub-points: onOutput location, exclusions, origin mismatch, shown≠panel, fix list, acceptance) |
| LM2 | yes |
| LM3 | yes |
| LM5 | yes |
| LM6 | yes |
| LM7 | yes |
| LM8 | yes |
| PF1 | yes |
| PF2 | yes |
| PF3 | yes |
| X12 | yes |
| B1 | yes |
| D5 | yes |
| P5 | yes |
| M07 (measurement bullets: smoke package, replay material, soak) | yes (the CI part is left to the other agent) |
