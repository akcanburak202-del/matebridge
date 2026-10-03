# Verification F: network transport, Wi-Fi congestion, bitrate control, control-channel queues

Scope: H03 (all sub-points), W2, A3, A4, X8, D6, IN11, LM7, W4 rows "Android session" and "Mac input".
HEAD = a30c769. All paths are relative to /home/user/matebridge.

Short answers to the orchestrator's questions:
- **Does the video sender look at TCP_NOTSENT_LOWAT, unsent bytes or srtt?** It looks at **unsent bytes only**. The `bsd` video socket sets `TCP_NOTSENT_LOWAT` = 128 KiB (`TransportKnobs.swift:98-113`, `SessionServer.swift:635-636`, `BsdTcpSocket.swift:303-305`). The sender takes a new frame only when no record of ours is in user space and `poll(POLLOUT)` says the kernel holds fewer than 128 KiB unsent (`BsdTcpSocket.swift:372-382`, `SocketVideoTransport.swift:9-16, 67-101`). **In-flight (unacked) bytes, srtt and cwnd are never consulted on the send path.** They are only logged once a second (T-126, `TcpInfoLog.swift`, `SessionServer` 1 s tick) and per frame when opted in (`ev=sendq`, T-088).
- **Is bitrate adapted automatically?** No. Bitrate is fixed per session: mode default → `STREAM_PREFS.bitrate_kbps` → env override (`TransportBitrate.swift:1-29`, `StreamPrefsPolicy.swift:21-27`). `STATS` from the client goes only to the overlay and logs (`StreamCoordinator.swift:226, 288-289`). Nothing feeds back.
- **Does a bitrate change restart the encoder?** Yes. A bitrate-only `STREAM_PREFS` gets a new `config_id`, sends `STREAM_CONFIG` and closes the video connection. The client then reconnects video, and capture plus encoder are rebuilt (`StreamCoordinator.swift:368-389` → `lease.reconfigure` → `.reconfigure` → `restartPipeline`, `StreamCoordinator.swift:555-570`; `DisplayLease.swift:51-56`). The virtual display is kept. PROTOCOL.md §0x05 host rules require this behaviour.
- **Can `VTSessionSetProperty(AverageBitRate)` be used live?** Nothing in the code does it today. `AverageBitRate` and `DataRateLimits` are set once at creation (`HEVCEncoder.swift:168-184`). The pattern itself already exists in this encoder: `MaxAllowedFrameQP` is changed on a live session before each submit (`HEVCEncoder.swift:430-452`, T-087). Outside this repo, WebRTC's VideoToolbox encoder updates `AverageBitRate` and `DataRateLimits` mid-session. So a live update is feasible. It still needs a device check on the M6 HEVC hardware encoder: how fast rate control follows, and whether `Quality` mode (T-086 knob) ignores it. There is a protocol consequence: `STREAM_CONFIG.bitrate_kbps` is documented as "the applied value". A host-internal adaptive bitrate needs either a doc-only semantics change ("ceiling") or a new message (see the proposed items).
- **How is the control channel's backlog bounded?**
  - Client C→H: app FIFO of 256 KiB / 1 s, followed by overflow, reconnect and host release-all (`SendQueue.kt:14-36`). Coalescing starts at 8 KiB / 50 ms (`SendQueue.kt:96-101`). The kernel send buffer behind the blocking writer is not bounded or observed (no `TCP_NOTSENT_LOWAT`, default `SO_SNDBUF`, `SessionController.kt:762-786`).
  - Host H→C: user-space bytes are capped at 256 KiB, and exceeding the cap drops the connection (`SessionServer.swift:1408-1438`, `controlSocketOptions` 318-330). Only `AUDIO_FRAME` is additionally gated on the kernel's unsent bytes, through the control `TCP_NOTSENT_LOWAT` of ~17 KiB plus a 19 KiB in-app cap (`SessionServer.swift:297-322, 791-815, 853-856`). Other messages (CLIPBOARD up to 60 KB, STREAM_CONFIG, PONG) go straight into the kernel.
  - Host C→H receive: no app queue. Bytes are decoded and delivered synchronously on the session queue, so the bound is the TCP receive window (see W4-Mac).
  - Client H→C receive: the reader blocks on the bounded `events` queue. Audio bypasses the engine and goes straight to the listener (`SessionController.kt:142, 715-760`).

---

## Verdicts

### H03 — Wi-Fi: app queue bounding not enough (overall)
- Verdict: **CONFIRMED** (substance), with corrections on two sub-points below.
- Evidence: see sub-points.
- Corrections: the review undersells what the kernel-socket gate already does. It bounds kernel **unsent** bytes, not just the app queue. The real gap is that **in-flight/unacked** bytes and the burst size of single large frames are not bounded.
- Severity opinion: agree with High **when Wi-Fi is the primary path**. For USB it is irrelevant: srtt is ~4.7 ms and send queue 0 (NOTES 2026-10-01 ~18:35).

#### H03.a — "SocketVideoTransport and BSD writable control bound only the app side; nothing manages by real age of data accepted by the kernel and in the network"
- Verdict: **PARTIALLY CORRECT**.
- Evidence:
  - `SocketVideoTransport.swift:73-75` gates on `inFlight < 1` and `connection.isWritableForNewRecord`.
  - That property is `outbound.isEmpty && poll(POLLOUT)` (`BsdTcpSocket.swift:372-382`). With `TCP_NOTSENT_LOWAT`, `POLLOUT` means fewer than 128 KiB are unsent in the kernel. So the kernel's unsent queue **is** bounded.
  - What is not bounded is bytes already sent but unacked. Those sit in AP/driver queues, and their size is limited only by `min(cwnd, rwnd)`. NOTES 2026-10-02 ~13:20 (`docs/NOTES.md:970-991`) shows video `snd_cwnd` at 2–13 MB, 100–450 KB in the air at once, and control srtt going from 20 to 60–100 ms.
  - A single large record (keyframe, full-screen change) is written as fast as the kernel takes it (`BsdTcpConnection.write` → `drainLocked`, `BsdTcpSocket.swift:392-416`). Nothing chunks or paces it.
  - No frame age or deadline is checked at send (`VideoSender.swift:218-259`).
- Corrections: "app side only" is wrong for video, because unsent kernel bytes are bounded. For the control channel, the lowat applies to audio only, so the review is roughly right there.
- Severity opinion: High for Wi-Fi primary use.

#### H03.b — "TransportBitrate is a fixed preference/env setting, not continuous measured adaptation"
- Verdict: **CONFIRMED**.
- Evidence:
  - `TransportBitrate.swift:1-29` only applies `MATEBRIDGE_WIFI_BITRATE_KBPS` once at session start (developer env, not user-facing).
  - The user bitrate in `STREAM_PREFS` is per device, not per transport (`StreamPrefsStore.swift:6-15`). The client has no per-transport bitrate setting (grep found no hits).
  - Defaults are 30 Mbps at 60 fps full size and 60 Mbps at 120 fps, capped at 80 Mbps (`StreamPrefsPolicy.swift:21-27`). The same defaults apply on Wi-Fi.
  - `STATS` and `ev=tcp` are not fed back.
- Corrections: none.
- Severity opinion: agree. It is part of the H03 core.

#### H03.c — "Changing bitrate preference today requires capture/encoder restart" [C35:369-389]
- Verdict: **CONFIRMED**.
- Evidence:
  - `StreamCoordinator.swift:373-389` (`applyPrefs`): new `config_id`, `onReconfigure` (STREAM_CONFIG plus video close), `lease.reconfigure`.
  - `DisplayLease.swift:51-56` returns `.reconfigure` when the display is the same.
  - `StreamCoordinator.swift:555-557` → `restartPipeline` (564ff) stops the consumer and rebuilds capture and encoder.
  - The client must reopen video with a new `VIDEO_HELLO` and gets a fresh IDR. PROTOCOL.md §0x05 host rules mandate this.
  - At most one reconfiguration per second (`prefsGate`).
- Corrections: the cited lines are accurate (actual 373-389). The virtual display is **not** recreated unless the refresh rate changes, which the review implies correctly. Note that the restart also costs a **keyframe on reconnect**, which is exactly the burst H03 is about. So the restart path is unusable as an adaptation mechanism.
- Severity opinion: agree.

#### H03.d — NOTES: full-screen bursts raise control srtt 20→60–100 ms, audio underruns [C02:973-989]
- Verdict: **CONFIRMED** (matches `docs/NOTES.md:970-991`).
- Evidence: the NOTES text quotes control srtt rising together with video `unacked` 78–148 KB, video in flight 100–450 KB, 13 underruns in 5 min, and no retransmits on the control socket. Pings stayed clean (`NOTES.md:964-968`).
- Corrections:
  - The measurement was taken with the **Mac also on Wi-Fi**: two wireless hops, channel 52 DFS 160 MHz, `awdl0` active (`NOTES.md:953`). It has never been repeated with the Mac on Ethernet (T-127 step 1 is still open).
  - The control socket already runs with `SO_NET_SERVICE_TYPE` VO and video with VI by default (T-124, `TransportKnobs.swift:21-60`). The finding therefore holds **despite** WMM marking. The review does not mention this mitigation.
  - The **tablet's uplink** (input and TCP ACKs) is unmarked by default. `tos_ctl` is only a launch knob (`WifiKnobs.kt`), and the T-089 test that found DSCP/`wifi_ll` "ineffective" (`NOTES.md:593-598`) ran under the old `nw` video ceiling. That result is confounded and should be re-run under `bsd`.
- Severity opinion: agree.

#### H03.e — Proposed fix (baseline matrix; measure unsent/unacked/RTT/frame size/receive age; deadline/age send budget; fast-down slow-up bitrate; live VT bitrate; bounded write chunks)
- Verdict: **CONFIRMED as a sound direction**. Each part maps onto concrete code (see the proposed items).
- Evidence:
  - Unsent and unacked can only be **estimated** on macOS: `unackedBytesEstimate = min(sbbytes, cwnd, snd_wnd)` (`TcpInfoLog.swift:218-226`). With cwnd in the MB range this estimate is in practice the whole send buffer. Treat the T-126 `unacked_bytes`/`notsent_bytes` fields as **sbbytes**, not as a true split.
  - There is a host-side "receive age" proxy only on the client (capture→decode output latency, LM2/H05 caveats).
- Corrections: "bounded write chunks" alone does not help if the chunks still leave at line rate. They have to be **paced in time** (macOS has no `SO_MAX_PACING_RATE`), or gated on in-flight bytes. The review does flag that this must be measured.
- Severity opinion: n/a (proposal).

#### H03.f — Acceptance (full-screen motion + pinch + audio; p95/p99 input-to-photon and underruns within a preset budget; a growing queue is not success; UDP/QUIC only after measurement)
- Verdict: **CONFIRMED as appropriate**. Today's instrumentation can produce part of it: `ev=tcp`, `ev=sendq`, audio `send`/`send_gap` (T-116), client audio arrival/underruns (T-117/T-123), and client latency. It **cannot** produce input-to-photon (H05/LM3, outside this area).
- Corrections: none.
- Severity opinion: n/a.

#### H03 vs existing card T-127 — overlap and proposal
T-127 (`backlog/tasks/T-127-wifi-video-burst-pacing.md`, status todo, owner orchestrator, the user said "Wi-Fi is fine for now") already captures:
- the diagnosis (100–450 KB bursts, unbounded cwnd, audio srtt and underruns);
- step 1: Mac on Ethernet, same test, `ev=tcp` srtt plus underrun count;
- step 2: lower the Wi-Fi bitrate from the panel and compare;
- step 3: a vague "limit in-flight bytes / send rate (pacing, `TCP_NOTSENT_LOWAT` + app byte budget)" host card;
- step 4: last resort, raise the Wi-Fi audio share to ~100 ms.

T-127 does **not** cover:
- automatic bitrate adaptation (fast-down, slow-up);
- a live encoder bitrate update without restart, and the `STREAM_CONFIG.bitrate_kbps` semantics question it raises;
- a deadline/age-based send budget;
- the three-topology baseline matrix (USB / Mac Ethernet + tablet Wi-Fi / both Wi-Fi) with pre-set p95/p99 budgets;
- uplink (input) freshness and the kernel age of the control channel (IN11);
- the host-side keyframe positive-feedback loop under congestion (see Additional issues A-1).

Roughly, T-127 holds about 40% of H03: the diagnosis and the manual steps.

**Proposal:**
- Keep the ID T-127 and **re-scope it as the measurement/baseline card** (owner orchestrator + user). It absorbs H03 baseline, X8 and D6 measurement, and its steps 1–2 become rows in the matrix. Its step 3 is **superseded** by proposed items F-2/F-3/F-4 below, and step 4 stays as a documented fallback.
- The new implementation cards depend on T-127's baseline (F-1 and F-6 can start in parallel because they are measurement/API-only).
- Mark T-019's Wi-Fi-lock part as superseded by T-089 (implemented as the `wifi_ll` knob). T-019's GL-jitter part is unrelated. Re-measure `wifi_ll` inside the T-127 matrix, since the 2026-10-01 result was confounded by the `nw` ceiling.

### W2 — Control connection carries pairing/settings/heartbeat/input/clipboard/audio; separate video connection; shared Wi-Fi/kernel queues → no physical priority guarantee
- Verdict: **CONFIRMED** (with additions).
- Evidence:
  - Control carries HELLO/ACK and pairing, PING/PONG, STREAM_PREFS/CONFIG, input, CLIPBOARD, AUDIO_*, and also STATS, KEYFRAME_REQUEST, DISPLAY_RATE, FILES_INFO, SETTINGS_OPEN (PROTOCOL.md §4 table, `SessionServer.swift:1473-1474` → `main.swift:156-161`).
  - Video is a separate TCP connection with its own keys (PROTOCOL §3.5, §9).
  - Audio is on control deliberately (decision 0011 §3).
  - The NOTES burst finding (`NOTES.md:970-991`) shows the control srtt is hit by video despite separate sockets and AC_VO.
- Corrections:
  - The review omits that the host **does** set WMM classes by default: control AC_VO, video AC_VI (T-124, `TransportKnobs.swift:21-60`; `BsdTcpSocket.swift:306-308`). This is best-effort marking on the Mac's radio and the DSCP the AP may honour.
  - The tablet uplink has **no** marking by default (`tos_ctl` knob absent, `SessionController.kt:636-642`).
  - So "no physical guarantee" is right, but "no priority attempt" would be wrong.
- Severity opinion: descriptive. It is the root of H03.

### A3 — Don't drop TCP first; H03 pacing/age/bitrate feedback and Mac Ethernet test first; split control/audio only if measured HOL benefit
- Verdict: **CONFIRMED** (consistent with project state).
- Evidence:
  - Moving video from `nw` to kernel BSD TCP removed the Wi-Fi ceiling: 372 ms → ~40 ms, zero retransmits (`NOTES.md:628-646`, T-091/T-092).
  - The control socket shows **no retransmits** even during bursts (`NOTES.md:975`). The delay is queueing, not loss, so UDP would not remove it.
  - PLAN.md:126 already defers the TCP vs UDP comparison. T-126 lists UDP/FEC as "a separate decision after measurement".
- Corrections:
  - PLAN.md:74 still states the original intent "switch to UDP if Wi-Fi jitter is seen". The review's ordering should be written into a decision (draft in F-0) so that PLAN does not contradict it.
  - A separate audio socket would not help either, since audio is already its own TCP flow (control). The HOL is in the AP queue, not in TCP.
- Severity opinion: agree (guidance).

### A4 — Datagram media only if loss-HOL breaks p95/p99 after backlog management; must co-design fragmentation, pacing, loss, CC, encryption, nonce, decoder recovery; input stays reliable
- Verdict: **CONFIRMED**, and the code confirms each coupling.
- Evidence:
  - Record nonce = implicit per-connection counter from 0 (PROTOCOL.md §9, around line 667). Datagram loss or reordering would desynchronise it, so an explicit nonce/sequence is needed.
  - Decision 0010 already lists "UDP video (record format changes)" as a revisit trigger.
  - `VIDEO_FRAME.fragment_*` is reserved but TCP requires single fragments (PROTOCOL.md:539).
  - Keyframes are on demand, with only a long safety-net interval (T-075, `HEVCEncoder.swift` `MaxKeyFrameIntervalDuration`). `BoundedFrameQueue` and `KeyframeRequestCoalescer` assume reliable delivery. Loss recovery would need intra-refresh/LTR or periodic IDR, which in turn costs bursts.
- Corrections: none.
- Severity opinion: agree (Low priority now).

### X8 — Wi-Fi stress row: full-screen pan/scroll, pinch + audio; USB/Ethernet/Wi-Fi same content → RTT, unacked, queue age, p95/p99, underrun, resync
- Verdict: **NOT VERIFIABLE IN CODE (needs device)**. Instrumentation inventory below.
- Evidence (available):
  - host `net ev=tcp` 1 Hz per socket on Wi-Fi by default: srtt, rttvar, rto, cwnd, snd_wnd, sbbytes, estimated unacked/notsent, retx/ooo deltas, loss_recovery (`TcpInfoLog.swift`, T-126);
  - host `ev=sendq` per frame, opt-in via `MATEBRIDGE_SENDQ_LOG=1` (T-088);
  - host audio `ev=send`/`send_gap` (T-116);
  - host keyframe window `idr=`/`idr_bytes_max=` (T-122);
  - client audio arrival/owd and underruns (T-117/T-123/T-125);
  - client capture→decode latency;
  - client stall detector, opt-in (T-142).
- Evidence (missing):
  - per-stage queue age (encoder-out → write-done → client read);
  - input sequence/ACK and input-to-photon (H05/M04 scope);
  - p95/p99 in a single run summary (some p95 exist in `FrameSizeStats`/`SendQueueStats`/`LatencyTrace`);
  - true unacked vs unsent (estimate only, see H03.e).
- Corrections: "unacked" must be documented as the `sbbytes` estimate on macOS.
- Severity opinion: agree that it is the needed gate.

### D6 — Wi-Fi topology & controlled flow (same workload over USB / Mac Ethernet + tablet Wi-Fi / both Wi-Fi; H03 budget, write pacing, in-session bitrate update; check a fixed conservative Wi-Fi profile first)
- Verdict: **CONFIRMED as a valid gap**. None of the D6 mechanisms exist in code.
- Evidence:
  - no in-session bitrate update (H03.c);
  - no write pacing (H03.a);
  - the "fixed conservative Wi-Fi profile" exists only as the developer env `MATEBRIDGE_WIFI_BITRATE_KBPS` (`TransportBitrate.swift`). It is not a user-facing or per-transport preference, because the user bitrate is stored per device for both transports (`StreamPrefsStore.swift`);
  - Mac Ethernet has never been measured (`NOTES.md:130, 1004, 1059, 1120`).
- Corrections: a cheap first lever the review does not name: a per-transport (Wi-Fi) default bitrate or a user "Wi-Fi bitrate" setting. The host already knows `transport` at session start (`applyingTransportKnobs`).
- Severity opinion: agree. Order: measure, then a fixed profile, then adaptation.

### IN11 — ControlLink coalesces safe motions after 8 KiB / 50 ms; hard limit 256 KiB / 1 s; releases/modifiers/stroke boundaries never dropped; kernel-accepted input age not bounded
- Verdict: **CONFIRMED**.
- Evidence:
  - `SendQueue.kt:96-101`: `CONGESTED_BYTES = 8*1024`, `CONGESTED_AGE_MS = 50`.
  - `SendQueue.kt:14, 25-36`: 256 KiB / 1000 ms. The first refusal latches `overflowed` → `onOverflow` → abort → reconnect (`SessionController.kt:593-597`).
  - `InputOutbox.kt:138-155, 205-226`: only mergeable messages are held and merged: plain-hover PEN, POINTER_REL with the same buttons, SCROLL CHANGED, PINCH CHANGED. Mergeable flags are set at `PenTracker.kt:355`, `RelPointerTracker.kt:379,464`, `TouchTracker.kt:149-163`. Anything else flushes the held message first, which matches PROTOCOL.md:555-563.
  - The writer `take()`s, seals and does a blocking `out.write` (`SessionController.kt:762-786`). Once a message leaves `SendQueue`, its age is invisible: no `TCP_NOTSENT_LOWAT`, default `SO_SNDBUF`.
- Corrections / missed points:
  1. **Contact pen samples and finger `POINTER_ABS` are never mergeable** (`TouchTracker.kt:417`, PenTracker contact path). During drawing on a stalled link the queue only grows, and the first relief is the 1 s overflow, which reconnects and releases the stroke on the host. This is correct by the "never drop stroke samples" rule, but it means a Wi-Fi stall of more than 1 s mid-stroke always becomes a visible stroke break.
  2. Because input volume is small (~20–30 KB/s at ~360 Hz pen), a Wi-Fi stall first fills the **kernel** buffer: Linux initial `tcp_wmem` is typically 16 KiB, which holds several hundred ms of pen data. Meanwhile the app queue stays empty, so `congested()` is false and nothing coalesces. The 50 ms congestion signal therefore reacts late on exactly the stalls it is meant for. The size depends on the device's `tcp_wmem` (device check).
  3. The age check runs only on `offer`. PINGs every 500 ms make sure it is evaluated.
- Severity opinion: Medium (it feeds M04 freshness). Fix candidate F-5.

### LM7 — "300 kB over 30 Mbit/s ≈ 80 ms" (not measured)
- Verdict: **PARTIALLY CORRECT**.
- Evidence:
  - The arithmetic holds: 300 kB × 8 / 30 Mbit/s = 80 ms.
  - But 30 Mbit/s is the **encoder's average target** (`StreamPrefsPolicy.swift:23-27`), not the link rate. Measured raw Mac→tablet Wi-Fi with a kernel socket was **~410 Mbit/s single flow**, and a 250 KB / 33 ms burst pattern was written with `sendall` p50 0.3 ms and no loss (`NOTES.md:603-613`). At link rate a 300 kB frame is ~6 ms of airtime per hop (~12 ms with the Mac also on Wi-Fi).
  - The observed tens of ms (srtt 60–100 ms) come from AP/driver queueing behind bursts and contention between two wireless hops, not from serialisation at the encoder rate.
  - Frame sizes are realistic: Wi-Fi `bsd` p50 46 KB, heavy content 188–275 KB, IDRs "hundreds of KB to ~1 MB" (`NOTES.md:632-640`, `KeyframeRequestCoalescer.swift:4-6`).
  - The encoder cap `DataRateLimits = 2× average per 1 s` (`HEVCEncoder.swift:182-184`) allows such single frames. There is no short-window cap.
- Corrections: the conclusion that large frames cost tens of ms on this Wi-Fi is empirically right, but for a different reason than the example gives. The 80 ms figure would only apply if the link were saturated at 30 Mbit/s, which was true of the old `nw` stack (~27–28 Mbit/s ceiling, `NOTES.md:589-598`), not of `bsd`.
- Severity opinion: Low (illustrative).

### W4 (Android session row) — engine + control read/write + video read; input can be sent without waiting for the 100 ms engine tick
- Verdict: **CONFIRMED**.
- Evidence:
  - Threads: `mb-session` engine (`SessionController.kt:322`), `mb-ctl-read-<gen>` (600), `mb-ctl-write-<gen>` (648), `mb-video-<gen>` (800), `mb-timer` (167).
  - The engine waits up to `tickMs` (100 ms by default, `engineTickMs`, 870-873) on the bounded `events` queue (327-345).
  - Input goes UI thread → `trySend`/`trySendInput` → `link.send` → `SendQueue.offer` (`SessionController.kt:278-295`) → writer thread. It does not pass through the engine or the tick.
  - Audio is delivered from the control reader straight to the listener (`deliverAudio`, `SessionController.kt:748`).
- Corrections:
  - The **reader** blocks on `events.put` when the engine is slow (`LinkedBlockingQueue(EVENT_QUEUE_CAP)`, line 142). A stalled engine therefore also stalls H→C audio behind it. This is bounded and intentional, but it is not mentioned.
  - `Codec.encode` runs on the UI thread and sealing on the writer thread.
- Severity opinion: agree that the design is fine.

### W4 (Mac input row) — input on its own serial queue, delivered synchronously from the session queue; can a slow OS call delay input and the watchdog?
- Verdict: **CONFIRMED** (deliberate design, risk unquantified).
- Evidence:
  - `main.swift:156-161`: `handlers.deliver` calls `coordinator.deliver` (non-blocking mailbox post, `StreamCoordinator.swift:135-151`), then `input.deliver`, then clipboard/files (async hops).
  - `InputController.swift:177-200`: `queue.sync` from the session queue. The header (lines 8-14) states that blocking the session queue is the intended back-pressure.
  - Each input message does the following on the input queue:
    - `environment()` → `isTrusted()` (AX call cached for 200 ms, 340-346);
    - `displays.geometry()` with `isOurs(id)` and bounds queries on **every message** (`VirtualDisplayLocator.swift:33-50`; CoreGraphics/WindowServer-backed);
    - `capsLock.isOn()` for keys;
    - `cursor.location()` for POINTER_REL (timed: avg ≈5 µs on device, `NOTES.md:723`);
    - then `CGEventPost` per event (untimed).
  - While this blocks, the **session queue** cannot:
    - read control bytes (`connection.start(queue: queue)`, `SessionServer.swift:1142-1190`);
    - run the 100 ms tick (heartbeat silence 1.5 s / timeout 5 s, `SessionMachine.swift:84, 514-521`);
    - drain audio (`drainAudio` runs on the session queue, `SessionServer.swift:783-815`);
    - answer PINGs (client PONG timeout is 3 s → reconnect, PROTOCOL.md §6).
  - The input pen/scroll watchdog (500 ms) runs on the **same** input queue (`InputController.swift:79-86, 380-388`). It is delayed along with input, but it could not post a release anyway while the poster is stuck.
- Corrections / missed points:
  1. The review frames the impact as "input and watchdog". The more likely visible effect of a slow input call is on **audio downlink**, which shares the session queue. The `sendAudio` doc says audio "never holds up input"; the reverse direction is not guarded.
  2. A false heartbeat-silence release needs a block longer than 1.5 s. Ordering between the pending read source and the tick on unblock is not guaranteed, so a single >1.5 s stall can release a held stroke. This is plausible only under a WindowServer hang.
  3. Per-message display lookups at ~360 Hz are also L03 territory.
  4. There is no per-call timing of `deliver`/`CGEventPost`, so the risk is unmeasured.
- Severity opinion: Low–Medium. Measure first (F-6); decouple only if p99 deliver time is more than a few ms.

---

## Additional issues found

**A-1. Host-side frame drops force an IDR without rate limit. Under Wi-Fi backpressure this is a positive-feedback loop (reasoned, needs device confirmation).**
- `VideoFrameQueue(keyframeNeeded:)` → `VideoPipeline.requestKeyframe()` (`VideoPipeline.swift:182-188`) is "always forced". `internalForce` only records the pending state (`KeyframeRequestCoalescer.swift:108-110`). Only client `KEYFRAME_REQUEST`s are coalesced (T-122), and `VideoSender`'s 500 ms limit applies only to *refused* frames (`VideoSender.swift:254-256, 276-283`), not to queue drops.
- When the socket gate stays closed for more than about two frame intervals, `BoundedFrameQueue.push` drops the oldest delta (`BoundedFrameQueue.swift:40-64`).
- The scan for a restarting keyframe goes **forward from the dropped index only**. With `[IDR, d1]` plus `d2`, it drops `d1`, purges `d2`, finds no keyframe after the index and requests **another** IDR, even though an IDR is still queued at the head. The next IDR (hundreds of KB) then lands on a link that is already congested.
- NOTES 2026-10-02 ~11:00/11:35 showed that IDR storms filled the link and starved audio. T-122 fixed the client-request side, not this host side.
- The T-122 `idr=`/`idr_bytes_max=` stats line can confirm the loop on device: look for many IDRs per second during Wi-Fi bursts.

**A-2. No pre-encode coupling to transport state.** The encoder keeps encoding at full fps while the socket gate is closed (no `canSend`/backpressure reference in `MateBridgeHost/Video` or `StreamCoordinator`). Frames are encoded and then thrown away in the 2-frame queue, which is the trigger for A-1. Skipping encodes while the sender is blocked (newest-frame-wins *before* encode) would avoid both the wasted encodes and the forced IDRs.

**A-3. Encoder burst cap is per second only.** `DataRateLimits = [2× avg bytes, 1 s]` (`HEVCEncoder.swift:182-184`). A short-window pair (e.g. 100 ms) would cap single-frame bursts on Wi-Fi. VideoToolbox's hardware HEVC support for multiple windows is unverified, but `propertyReport` would show acceptance.

**A-4. Host H→C control: only audio respects the kernel low-water mark.**
- CLIPBOARD (up to 60 KB), STREAM_CONFIG and PONG go straight into the kernel behind whatever is unsent (`SessionServer.swift:1389-1438`). This is not harmful today (low volume).
- Note that the 256 KiB `maxInflightBytes` overflow path **drops the session** (`transportClosed`). A peer that stops reading during a stall longer than ~2 s with audio on can hit it: audio is capped at 19 KiB, so in practice only clipboard bursts can. Low.

**A-5. The T-126 `unacked_bytes`/`notsent_bytes` split is an estimate that degenerates when cwnd ≫ sbbytes.** Then `unacked = sbbytes` and `notsent = 0` (`TcpInfoLog.swift:218-226`). Anyone reading NOTES numbers ("video unacked 78–148 KB") should read them as **send-buffer bytes**. Worth a line in LOGGING.md and in the T-127 measurement procedure.

---

## Proposed work items

### F-0 — Decision record: Wi-Fi congestion handling stays on TCP; app-layer in-flight budget + live bitrate adaptation
- owner: orchestrator
- depends_on: [T-127 (re-scoped baseline)]
- Needs decision: **yes**, new `docs/decisions/0018-wifi-congestion-control.md`. Draft:
  > Context: on Wi-Fi, full-screen changes push 100–450 KB per frame into the air. Control srtt rises 20→60–100 ms and audio underruns despite separate sockets and WMM classes (NOTES 2026-10-02 ~13:20). There is no loss, so this is queueing, not loss.
  >
  > Decision: keep TCP for video and control (A3). Bound video **in-flight** bytes, not only unsent bytes. Adapt the encoder bitrate inside the session (fast-down on queueing signals, slow-up), between a floor and the configured bitrate. Never use the restart path for adaptation. `STREAM_CONFIG.bitrate_kbps` becomes the **ceiling** the session was configured with; the host may encode below it without a new config_id. User changes via `STREAM_PREFS` keep the restart path until a separate decision. Datagram transport is reconsidered only if, after this, retransmission-driven p99 dominates (A4).
  >
  > Consequences: PROTOCOL.md §0x03 text change only (no wire or fixture change); PLAN.md:74 updated; T-127 step 3 superseded.
- Wire protocol: **doc-only**. Semantics of `STREAM_CONFIG.bitrate_kbps` ("target" → "ceiling; host may run lower under congestion"). No field, size or fixture change, so fixtures `stream_config*` stay unchanged.
- files: `docs/decisions/0018-wifi-congestion-control.md`, `docs/PROTOCOL.md` (§0x03 row text, §5 video note), `docs/PLAN.md` (§4 line 74, §line 126), `backlog/tasks/T-127-wifi-video-burst-pacing.md`.

### T-127 (re-scoped) — Measure the Wi-Fi baseline across three topologies before any congestion code
- owner: orchestrator + user (hardware). depends_on: [T-126]. Needs decision: no. Wire protocol: no.
- files: `backlog/tasks/T-127-wifi-video-burst-pacing.md`, `docs/NOTES.md` (append).
- Goal: produce the H03/X8/D6 baseline. Run the same scripted workload (full-screen pan/scroll, Krita pinch, app switch, Apple Music playing, 5 min) over (1) USB, (2) Mac Ethernet + tablet Wi-Fi, (3) both on Wi-Fi. Then decide whether a fixed Wi-Fi bitrate profile is enough before writing F-2/F-3.
- Out of scope: code changes.
- Acceptance:
  - [ ] Per topology, ≥3 runs, recording: host `ev=tcp` (control and video srtt p50/p95/max, sbbytes p95/max, retx), `ev=sendq` (`MATEBRIDGE_SENDQ_LOG=1`), host `idr=`/`idr_bytes_max=` per second (A-1 check), client audio underruns/owd, client latency p50/p95, fps.
  - [ ] Repeat topology (3) with Wi-Fi bitrate at the default, 30 and 15 Mbps via the panel (old T-127 step 2).
  - [ ] Repeat topology (3) with `--ei tos_ctl 0xB8 --ez wifi_ll true` (the 2026-10-01 result was confounded by `nw`).
  - [ ] AWDL state noted (`ifconfig awdl0`), channel/width/DFS noted.
  - [ ] Pre-set budgets written down before the runs (proposal: audio underruns ≤ 1 per 5 min; control srtt p95 ≤ 40 ms; client latency p95 ≤ 70 ms on Wi-Fi).
  - [ ] Result and decision ("fixed profile suffices" / "go F-2/F-3") in NOTES.
- Plan hints: read `unacked_bytes` as `sbbytes` (A-5). Measure Ethernet first (T-127 step 1), since it may remove half the problem.

### F-1 — Host: add a live encoder bitrate setter (no restart) and verify VideoToolbox honours it
- owner: mac-host-dev. depends_on: [] (parallel with T-127). Coordinate with M02's encoder-owner work if that card lands first: the setter must go through the same owner/lock as submit/invalidate. Needs decision: no (internal API). Wire protocol: no.
- files: `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift`, `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`, `host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift` (debug knob only), `host-mac/Tests/MateBridgeCoreTests/Video/`, `docs/LOGGING.md`, card.
- Goal: `HEVCEncoder.setTargetBitrate(kbps:)` updates `AverageBitRate` (unless `Quality` mode) and `DataRateLimits` on the live `VTCompressionSession`, with no capture or encoder restart and no `config_id` change. Also add a debug-only knob that steps the bitrate on a timer, to verify on the device how quickly frame sizes follow.
- Out of scope: any controller deciding *when* to change (F-2); changing the STREAM_PREFS restart path.
- Acceptance:
  - [ ] Setter is serialised with submit/invalidate (no call after `stop`). A unit test on a pure "rate request" value type: clamping to [floor, ceiling], dedupe of equal values. XCTest.
  - [ ] Log `video ev=bitrate_set kbps= status=` (numbers only).
  - [ ] Device (orchestrator): with the step knob 60→15→60 Mbps on a scrolling page, the per-second bytes in `ev=stats` follow within ≤ 1 s, there is no video reconnect, and there is no `STREAM_CONFIG`. Record the `VTSessionSetProperty` status codes.
  - [ ] `./scripts/check.sh` passes.
- Plan hints: precedent at `HEVCEncoder.swift:430-452` (live `MaxAllowedFrameQP` under `boostLock`). Creation-time sets are at `HEVCEncoder.swift:168-184`. Risk: the hardware encoder with `RealTime=false` may react slowly. Measure it rather than assume.

### F-2 — Core: write a pure Wi-Fi congestion controller (in-flight budget + fast-down/slow-up bitrate)
- owner: mac-host-dev. depends_on: [T-127 result, F-0]. Needs decision: yes (F-0). Wire protocol: no.
- files: `host-mac/Sources/MateBridgeCore/Video/CongestionController.swift` (new), `host-mac/Tests/MateBridgeCoreTests/Video/CongestionControllerTests.swift` (new), card.
- Goal: a pure value type, fed per completed frame write (bytes, write start/done µs, keyframe), per 100 ms tick (`TcpConnectionSnapshot`: srtt, sbbytes, retx delta) and per queue-drop event. It outputs (a) admission: whether a new frame may be written now, based on `sbbytes` against an in-flight budget, and (b) a target bitrate within [floor, ceiling]. Fast-down is multiplicative (e.g. ×0.7, at most once per srtt) when srtt rises over its baseline by a threshold, sbbytes exceeds its budget, or a queue drop happens. Slow-up is additive (e.g. +5% per second) after a quiet period.
- Out of scope: wiring into the socket path (F-3); USB (controller disabled on loopback).
- Acceptance (all XCTest):
  - [ ] Step response to a synthetic srtt spike: bitrate falls within one srtt and recovers no faster than the configured slope.
  - [ ] Never above the ceiling, never below the floor; no oscillation in a constant-RTT trace.
  - [ ] Replay of a recorded `ev=tcp` trace (from T-127, anonymised numbers only) produces a sensible bitrate trace (golden file).
  - [ ] `./scripts/check.sh` passes.
- Plan hints: baseline srtt as a windowed minimum. Budget ≈ target_rate × target_queue_delay (e.g. 20 ms), with a floor of one average frame. Do not use the cwnd-based `unacked` estimate (A-5); use `sbbytes`.

### F-3 — Host: wire the congestion controller into the video send gate and the encoder (Wi-Fi only, behind a knob)
- owner: mac-host-dev. depends_on: [F-1, F-2]. Needs decision: covered by F-0. Wire protocol: no (PROTOCOL text from F-0 only).
- files: `host-mac/Sources/MateBridgeCore/Video/SocketVideoTransport.swift`, `host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift` (read-only accessors if needed), `host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift`, `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift` (VideoLink), `host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift`, `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`, `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`, `host-mac/Tests/MateBridgeCoreTests/`, `docs/LOGGING.md`, card.
- Goal: on `transport=wifi` with `MATEBRIDGE_WIFI_ADAPT=1` (default off until a device A/B), the `bsd` video gate also requires the controller's admission. A cheap `TCP_CONNECTION_INFO` read per frame or per tick supplies sbbytes. The controller's target bitrate is applied through F-1. Optionally, large records (> N KB) are written in paced chunks inside one record. The record counter still cannot be split, so pace the `write()` calls, not records.
- Out of scope: USB, UDP, client changes.
- Acceptance:
  - [ ] Off: byte-identical behaviour to today (XCTest on the gate with a fake socket).
  - [ ] On: unit test that admission blocks when the fake sbbytes exceeds the budget and wakes on writable or tick.
  - [ ] `video ev=adapt` line once a second: target_kbps, sbbytes_p95, srtt, admits_blocked.
  - [ ] Device (orchestrator, T-127 procedure, topology 3): audio underruns and control srtt p95 against the baseline at equal or better client latency p95. Sharpness on static text is unchanged (the bitrate recovers when idle). Results in NOTES.
  - [ ] `./scripts/check.sh` passes. Run `codex-review.sh` (transport change).
- Plan hints:
  - Precedent for reading socket info: `TcpSocketProbe`/`TcpInfoSampler`. Keep `getsockopt` off the hot path if expensive: sample on the write-completion queue, not per `canSend`.
  - Risk: the double wake path (writable handler plus tick) must not lose a wake-up. The `SocketVideoTransport` lock order is the transport lock, then the connection lock.

### F-4 — Host: stop forced-IDR feedback on host-side queue drops
- owner: mac-host-dev. depends_on: []. Can run before T-127, but measure with T-127's `idr=` data. Needs decision: no. Wire protocol: no.
- files: `host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift`, `host-mac/Sources/MateBridgeCore/Video/VideoFrameQueue.swift`, `host-mac/Sources/MateBridgeCore/Video/KeyframeRequestCoalescer.swift`, `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`, `host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift` (encode-skip hook only), `host-mac/Tests/MateBridgeCoreTests/Video/`, card.
- Goal: under transport backpressure, (a) host-side drops do not force a new IDR while one is still queued or pending, or was written within the coalescing window. (b) Optionally, the pipeline skips submitting new captures while the sender has been blocked for more than one frame interval, so drops and IDRs are not created in the first place (newest-frame-wins before encode).
- Out of scope: client keyframe logic; protocol.
- Acceptance:
  - [ ] XCTest: `[IDR, d1] + d2` no longer yields `keyframeNeeded` when a queued IDR exists ahead of the dropped delta. The stream stays decodable: deltas after the queued IDR are still refused until the next IDR, or the queue keeps IDR+d1 and drops newest. Document which, with the reference-chain argument.
  - [ ] XCTest: `internalForce` is coalesced like `FRAMES_DROPPED` within `windowUs`, and nothing is swallowed forever (pending timeout).
  - [ ] Device: during Wi-Fi full-screen bursts, `idr=` per second is lower than the T-127 baseline with no increase in client `frames_dropped`/decode errors.
  - [ ] `./scripts/check.sh` passes. Run `codex-review.sh` (keyframe/reference-chain logic).
- Plan hints: `BoundedFrameQueue.swift:40-64` scans for a restarting keyframe only forward. `VideoPipeline.swift:182-188` is the unconditional force. The encoder's `requestKeyframe(resubmitNow:)` is at `HEVCEncoder.swift:307-310`.

### F-5 — Client: expose kernel backlog of the control socket to the input layer (experiment knob)
- owner: android-client-dev. depends_on: [T-127 baseline]. Needs decision: no (experiment knob). It needs one if made default. Wire protocol: no.
- files: `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt`, `client-android/app/src/main/kotlin/dev/matebridge/client/session/QuickAck.kt` (reuse its fd helper) or a new `session/NotSentLowat.kt`, `client-android/app/src/main/kotlin/dev/matebridge/client/session/WifiKnobs.kt`, `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (knob parse only), `client-android/app/src/test/kotlin/dev/matebridge/client/session/`, card.
- Goal: with `--ei ctl_lowat_kb N`, set Linux `TCP_NOTSENT_LOWAT` (option 25) on the control socket after connect. The blocking writer then stops early when unsent bytes pile up, so `SendQueue` age/bytes, and therefore `congested()` coalescing and the 1 s bound, see a Wi-Fi stall within tens of ms instead of after the kernel buffer fills. Also log `tcp_wmem`-relevant `sendBufferSize` once.
- Out of scope: changing the 256 KiB / 1 s bounds; dropping contact samples (M04 owns freshness policy).
- Acceptance:
  - [ ] JVM test for the knob parse and the setsockopt wrapper (failure → logged once, session unaffected), modelled on `QuickAckTest`.
  - [ ] Session-start log field `ctl_lowat_kb=`.
  - [ ] Device (orchestrator, Wi-Fi topology 3, hover plus scroll during a forced burst): count of `congested` episodes and merged hover samples against the baseline, and reconnect count (must not rise in normal use).
  - [ ] `./scripts/check.sh` passes.
- Plan hints: Linux applies `notsent_lowat` to blocking `sendmsg` through `sk_stream_memory_free`. Verify on the HarmonyOS kernel, since the option may be refused. Risk: the overflow path (reconnect + release) triggers sooner on long stalls. That is correct semantically but user-visible, so keep the default off.

### F-6 — Host: measure synchronous input delivery time on the session queue
- owner: mac-host-dev. depends_on: []. Needs decision: no. Wire protocol: no.
- files: `host-mac/Sources/MateBridgeHost/Input/InputController.swift`, `host-mac/Sources/MateBridgeCore/Input/` (pure stats helper if needed), `host-mac/Tests/MateBridgeCoreTests/Input/`, `docs/LOGGING.md`, card.
- Goal: quantify the W4 risk. Time each `deliver` block (environment sampling vs `CGEventPost`) and report per session `deliver_us_avg/p99/max` and `post_us_max` in `input_session_end`, plus a rate-limited warning when one call exceeds 20 ms. Decide on decoupling only with data, e.g. moving `drainAudio` off the session queue with a sealer lock, or caching display geometry on change notifications (L03).
- Out of scope: changing the threading model.
- Acceptance:
  - [ ] Pure histogram/aggregate tested in XCTest. No coordinates or keys logged (LOGGING rules).
  - [ ] Device: 10 min mixed pen/keyboard/trackpad use, with numbers in NOTES. Also test during a display-reconfigure event (mode switch) to find the worst case.
  - [ ] `./scripts/check.sh` passes.
- Plan hints: `InputController.swift:177-200` (deliver), `320-338` (environment), `283-308` (post/flush). Existing cursor-query timing pattern is at `251-260`.

### F-7 (optional, after T-127) — Host + client: per-transport (Wi-Fi) default bitrate as a user-visible profile
- owner: orchestrator decides. Then mac-host-dev, plus android-client-dev for the panel.
- depends_on: [T-127 result].
- Needs decision: yes (extends 0013): either a host-side Wi-Fi default with no wire change, or a separate Wi-Fi bitrate in `STREAM_PREFS`, which would be a **wire change**: new field or flag in `STREAM_PREFS`, PROTOCOL.md §0x05, new fixture `stream_prefs_wifi`, both fixture tests.
- Recommendation: the host-only variant first (`VideoSettings` default by `transport`, `TransportBitrate.swift`), no protocol change.
- files (host-only variant): `host-mac/Sources/MateBridgeCore/Video/TransportBitrate.swift`, `host-mac/Sources/MateBridgeCore/Video/StreamPrefsPolicy.swift`, `host-mac/Tests/MateBridgeCoreTests/Video/`, card.
- Goal: the cheap D6 "fixed conservative Wi-Fi profile", if T-127 shows it is enough.
- Acceptance: the mode default on `transport=wifi` uses the Wi-Fi value; user and env priority unchanged (decision 0013); XCTest; device check via the T-127 procedure.

---

## Coverage
| Claim | Verdict entry |
|---|---|
| H03 (overall) | yes — CONFIRMED |
| H03.a app-side bounding / kernel age | yes — PARTIALLY CORRECT |
| H03.b TransportBitrate fixed | yes — CONFIRMED |
| H03.c bitrate change restarts | yes — CONFIRMED |
| H03.d NOTES srtt/underruns | yes — CONFIRMED |
| H03.e fix proposal | yes — CONFIRMED (direction) |
| H03.f acceptance | yes — CONFIRMED |
| H03 vs T-127 overlap | yes — merge/supersede proposal |
| W2 | yes — CONFIRMED |
| A3 | yes — CONFIRMED |
| A4 | yes — CONFIRMED |
| X8 | yes — NOT VERIFIABLE IN CODE (needs device) |
| D6 | yes — CONFIRMED (gap) |
| IN11 | yes — CONFIRMED |
| LM7 | yes — PARTIALLY CORRECT |
| W4 Android session | yes — CONFIRMED |
| W4 Mac input | yes — CONFIRMED |
