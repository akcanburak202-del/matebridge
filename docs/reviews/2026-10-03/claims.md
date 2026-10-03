# External review (2026-10-03, main @ a30c769) — exhaustive claim checklist

Source PDF: /root/.claude/uploads/31094e4b-af73-5ea1-9de8-cdc12d4c86e1/cc6c9452-MateBridge-Mimari-Inceleme-2026-10-03.pdf
(25 pages, Turkish. Page numbers below = PDF page.) Repo: /home/user/matebridge (HEAD == a30c769 for code).
Reference index (page 25): C01 README.md; C02 docs/NOTES.md; C03 host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift;
C04 .../Video/HEVCEncoder.swift; C05 .../Video/VideoPipeline.swift; C06 host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift;
C07 Core/Video/VideoSender.swift; C08 Core/Video/SocketVideoTransport.swift; C09 Core/Session/BsdTcpSocket.swift;
C10 client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt; C11 client/video/FrameQueue.kt;
C12 client/video/VideoRenderer.kt; C13 client/video/AdaptivePacer.kt; C14 client/video/SlotReleaser.kt; C15 client/video/VideoStats.kt;
C16 client/stream/ClockSync.kt; C17 client/MainActivity.kt; C18 client/input/MotionEventAdapter.kt; C19 client/input/PenTracker.kt;
C20 client/protocol/Coords.kt; C21 client/input/UnbufferedPenDispatch.kt; C22 client/input/InputCapture.kt; C23 client/input/InputOutbox.kt;
C24 client/session/SendQueue.kt; C25 host Input/InputController.swift; C26 Core/Input/InputStateMachine+Pen.swift; C27 host Input/CGEventPoster.swift;
C28 Core/Input/InputPipeline.swift; C29 client/security/Handshake.kt; C30 client/session/SessionMachine.kt; C31 Core/Crypto/KeySchedule.swift;
C32 client/security/Records.kt; C33 host Session/SessionServer.swift; C34 Core/Video/DisplayLease.swift; C35 host Session/StreamCoordinator.swift;
C36 Core/Video/TransportBitrate.swift; C37 host-mac/Sources/MateBridgeApp/LoginItem.swift; C38 host Input/MagnifyGestureEvent.swift;
C39 client/files/FilesController.kt; C40 client/files/DavServer.kt; C41 scripts/check.sh; C42 client-android/app/build.gradle.kts;
C43 docs/PLAN.md; C44 client-android/app/src/test/kotlin/dev/matebridge/client/security/CryptoVectorsTest.kt; C45 client-android/app/src/main/cpp/mbaudio.cpp;
C47 client AndroidManifest.xml; C48 client/security/PairKeyStore.kt; E01 Android stylus palm rejection docs; E02 MediaCodec.OnFrameRenderedListener docs.
(Paths are as cited by the report; actual paths may differ slightly — find them.)

Evidence tags used by the report: K = seen in source; N = owner's NOTES; R = inferred race/risk; Ö = proposal.

## p1–2 Executive summary
- S1 Verdict: "hardware-tested personal beta"; do not rewrite; prioritise trust boundary, video health, virtual display continuity, real e2e measurement; then Wi-Fi.
- S2 Five top results = H01..H05 (below). 0 Critical, 5 High, 7 Medium, 3 Low.
- S3 USB fine for personal daily trial with rollback path; Wi-Fi as sole main screen needs H01–H05 + acceptance tests.

## p3 Scope/method
- P1 README still describes early Phase 0; real scope much larger. [C01 C02 C43]
- P2 `python3 protocol/fixtures/gen.py --check` passed; 48 .hex fixture names all present in PROTOCOL.md.
- P3 68 Swift files in host test tree, 98 Kotlin files in client JVM test tree.
- P4 No .github/workflows and no client androidTest tree at that commit; no visible automated platform gate.
- P5 NOTES: old ~110 fps decoder-ceiling estimate disproven by later 120 fps experiment [C02:1100-1113].

## p4 How the system works (descriptive; verify accuracy)
- W1 Host: CGVirtualDisplay → SCK → NV12 → VideoToolbox HEVC → Annex-B/protocol record, encrypted, sent over dedicated video TCP. Client: reader → FrameQueue (protects reference chain) → MediaCodec → SurfaceView; GL presentation optional/experimental. [C03 C04 C05 C07 C10 C11 C12]
- W2 Control connection carries pairing, settings, heartbeat, input, clipboard, audio. Separate video connection prevents a big video record ahead of a key message in the same app FIFO, but shared Wi-Fi/kernel queues → no physical priority guarantee.
- W3 USB uses adb tunnel with same session/protocol. Bonjour/manual endpoint/saved target. Session generations, proven peer keys, video-connection-specific nonce/proof limit channel takeover. [C10 C30 C31 C33]
- W4 Thread map: Mac capture separate userInteractive callback queue (ok); Mac encode = locked state + capture/timer/VT callback calls (in-flight limit good; call & stop order = M02 risk); Mac session serial queue; Mac input separate serial queue, synchronous delivery from session (slow OS call can delay input & watchdog); Mac socket read-owner queue + separate write queue (size limits, close-once); Android UI MotionEvent/KeyEvent, input model, Surface lifecycle (big MainActivity maintenance risk); Android session engine + control read/write + video read (input can be sent without waiting 100 ms engine tick); Android codec input & output threads (pipeline overlaps; teardown ownership = M03 risk); Audio separate playout/writer + small AAudio JNI layer (native stream managed by single writer). [C25 C33 C45]

## p5 Video chain table (verify each row)
- V1 Capture: SCK minimumFrameInterval = 1/(fps*2), queueDepth=5; changed complete frames processed.
- V2 Pre-encode: max 2 encodes in flight, 1 newest pending frame.
- V3 Encode: VideoToolbox, hardware acceleration *requested*, B-frame reordering off. Default fast profile RealTime=false; don't judge it slow by its name.
- V4 Post-encode: ~2-frame bounded frame queue; keyframe/resync rules.
- V5 Network write: one app record in flight; writable/TCP not-sent threshold.
- V6 Receive: TCP read, full-record accumulation, GCM verification, frame parse.
- V7 Decode queue: 64 ms short burst capacity; 4 frames at 60 fps, 8 at 120 fps; no age/deadline limit separately; queue adds held frames + codec work.
- V8 MediaCodec: input/output threads running independently (not necessarily callback mode); maxInFlight default 0 = no app-level limit (codec memory not infinite; input-buffer wait / output wait can accumulate).
- V9 Render: AdaptivePacer + single waiting SlotReleaser buffer + Surface.
- V10 Queues must be measured together (age + occupancy per stage). Don't randomly drop HEVC P-frames pre-decode; keep keyframe gate, overflow→resync, request coalescing. NOTES keyframe-storm fix [C02:911-939].

## p6 Latency measurement
- LM1 Encode time = submit→VT callback only.
- LM2 Client "latency" = clock-aligned diff host capture timestamp → decode output; VideoStats.onOutput called before pacing and releaseOutputBuffer. Capture timestamp ≠ physical pixel creation. [C12:539-573 C15 C16]
- LM3 True input-to-photon not measured by any counter.
- LM4 Host FrameTrace.origin uses earliest of displayTime/PTS/callback; captureTimeUs sent to client is the existing (legacy) stamp set in send() → host totals and client latency not same origin. NOTES: SCK times ~6.6 ms ahead of callback. [C04:550-575 C02]
- LM5 ClockSync: midpoint estimate from low-RTT sample; Wi-Fi asymmetry hides one-way error; clamping negative to zero hides clock error. [C16]
- LM6 AdaptivePacer limits jitter pad to one period in locked cadence, 1.5 periods elsewhere; SlotReleaser overlapping slot shift & Surface queue must be tracked; not a hard deadline. [C13:183-229 C14:43-69]
- LM7 Example: 300 kB over 30 Mbit/s ≈ 80 ms (not measured on device).
- LM8 Proposal: unify frame ID + session/config generation across stages; p50/p95/p99 + oldest-work age; input sequence ID + host injection ACK; OnFrameRenderedListener caveats (API31); optical 240 fps camera measurement. [E02]

## p7 Input chain and pen model
- IN1 Flow: MotionEvent/KeyEvent → adapters/trackers on UI thread; InputCapture manages device/gesture state; InputOutbox coalesces only safe types; ControlLink bounded SendQueue → TCP writer; Mac session after protocol/identity check delivers synchronously to InputController serial queue; pure InputStateMachine produces actions; InputPipeline tracks owed releases; CGEventPoster posts to HID event tap. [C18 C22-C28]
- IN2 Coordinates: viewport-normalized u16 → Mac display point geometry; 2800 px over u16 ≈ 0.043 px step.
- IN3 Pressure: MotionEvent pressure u16 → CGEvent double 0..1; NOTES ~14-bit physical pressure; contact from CONTACT flag not pressure.
- IN4 Tilt: AXIS_TILT + ORIENTATION, sine-based tiltX/tiltY; sign/axis & physical calibration need verification; synthetic unit test alone insufficient.
- IN5 Hover: HOVER_ENTER/MOVE/EXIT, IN_RANGE, proximity; AXIS_DISTANCE always 0; no height support claim.
- IN6 Drag: contact down/drag/up; STROKE_START latch prevents mid-stroke becoming new press on reconnect.
- IN7 Pointer ownership: pen/touch/mouse-left ownership managed; protects against one source dropping the other's cursor.
- IN8 History samples: MotionEvent history + current carried; host doesn't apply original time intervals.
- IN9 Unbuffered dispatch: API30+ source mask, API29 fallback.
- IN10 PenTracker ~10 ms confirmation threshold to filter spurious contact; second real sample can confirm early (330-362 Hz in NOTES); tick-based resolution can rarely be affected by the 25 ms check (tick) interval; hover exit delayed ~40 ms to reduce proximity flicker. [C19]
- IN11 ControlLink starts coalescing safe motions after 8 KiB or 50 ms backlog; hard queue limit 256 KiB / 1 s; release, modifier transition, stroke boundaries never dropped as ordinary motion. Kernel-accepted input age not bounded. [C23 C24]

## p8 Pen / palm / mouse / keyboard
- PK1 Mac side posts mouse events with tablet identity/proximity, tablet-point subtype, pressure & tilt fields — does NOT post plain mouse position only. Krita 5.3.4 pressure drawing tested (N). [C27 C02]
- PK2 NOTES: tilt during contact takes few distinct values; more during hover. Need to separate HW/firmware/API limit from app bug. Validate 4 directions, 2 landscape orientations, 4 corners + centre for pressure/tilt/hover/eraser. [C18 C20]
- PK3 Separate tests: light first touch, slow pressure ramp, contact at zero pressure, short dot, panel open during drag, network drop, device removal. Short-contact filter must not swallow real small dots. Pressure curve linear by default; avoid double curve.
- PK4 Palm: adapter honours ACTION_CANCEL and device/pointer identity; finger/stylus separation, pen ownership, release policies useful. Full palm rejection is app's job; Android 12/API31 target can't separate unwanted contacts in multi-pointer ACTION_POINTER_UP without normal lift; Android 13+ FLAG_CANCELED stronger. [C18 C22 E01]
- PK5 A palm click already sent to Mac can't be undone by later CANCEL. Optional policy during pen proximity/contact: "finger only navigates" or "finger input off". Narrow policy protecting pinch. Don't promise perfect palm rejection on API31.
- PK6 Mouse/keyboard: relative mouse/pointer capture, history delta, key ownership fit desktop. Physical scan-code keyboard; host repeat logic dedups Android repeats. Up uses mapping chosen at down; modifier ordering & ordinary-key-before-modifier release reduce stuck keys. [C18 C22 C25 C28]
- PK7 Real-app tests needed: Turkish Q, ISO extra key, Option/Command combos, dead keys, Caps Lock, repeat, keyboard detach, secure text fields. Physical keyboard ≠ IME/preedit/compose; text composition is a separate product need.
- PK8 Cursor embedded in capture (showsCursor=true) → remote cursor feedback via video path. Future local cursor layer could reduce perceived mouse latency; avoid drift/double cursor. Local pen trail/prediction only feedback. Measure real latency first. [C03]

## p9 Performance / refresh / quality
- PF1 Oct 3 notes: USB 60-second drawing trials; selecting only dense windows (≥100 frames/s received), median 121/121 fps at 2800x1840 received/shown; decode avg median 9.3 ms; current latency median 10.6 ms; host encode p50 ~7.2 ms. Project-internal; not optical p95/p99 or sustained. "Shown" ≠ physical panel. [C02:1100-1113 C15]
- PF2 Decode >8.33 ms doesn't make 120 fps impossible (pipeline overlap). No equivalent e2e evidence for 144 Hz.
- PF3 Huawei panel policy depends on content/input type; 120 Hz with pen/mouse/touchpad, panel stays 60 Hz with keyboard/gamepad no-touch game. Animation & reflection experiments failed, default off. [C02:1062-1098]
- PF4 SCK NV12 CVPixelBuffer → VT, decoder output → Surface directly: right base; no CPU RGB scaling. But compressed byte conversions, crypto record copies, codec input copy → not "zero copy". [C03 C04 C12:454-472 C32]
- PF5 Biggest unnecessary GPU load: target app may render 120 fps while panel is 60 Hz; decimating encode to 60 later doesn't recover app work. Game 60 mode right direction; NOTES Mac GPU ~90%→54%. Mode switch can recreate display → prefer stable profile over auto frequent switching. [C02:1089-1098 C05]
- PF6 NV12 4:2:0 SDR limits small coloured text edges & colour accuracy; bitrate doesn't restore chroma. sRGB/709 tags ok to reduce conversion cost but verify metadata vs real conversion with colour ramps, thin red/blue text, full/limited-range B/W samples. Don't assume colour-critical P3/HDR. [C03 C04:312-334]
- PF7 Full resolution valuable for small text. 90% scale gains ~1 ms decode but costs sharpness. Optimise bitrate & motion profile first, then resolution/fps. Keep RealTime=false (fast) based on experiments. Verify at startup that hardware encoder/decoder actually selected; enableHardware request isn't guarantee.

## p10 Security / connection / resources
- SE1 Keep: ECDH P-256, transcript-bound HKDF, previously paired key contribution on reconnect, per-direction keys, AES-GCM records. Separate video nonce & proof; prevents video leak outside session. Keys in host Keychain, tablet Keystore-protected storage; client backup off. Logs write events/sizes not text/clipboard content/pairing code. [C29 C31 C32 C47 C48]
- SE2 Size checks, handshake/proof timeouts, unauthenticated connection limit, preventing input injection before approval important. No proven path to Mac control/remote code exec without auth. H01 = missing re-verification of trusted host; old PSK doesn't give access to real Mac. [C33]
- SE3 Reconnect/state recovery: session generations, video config ID, reset old input model, ownership, release-all, owed-release replays, pen stroke latch consistent. Host input silence, pen watchdog, disconnect & focus/background release paths reviewed. Audio & clipboard have old-generation-drop guards. [C22 C25 C28 C10]
- SE4 'TCP connected', 'video decoding', 'user sees current screen', 'input safe to be on' must not be same state. Three cases make this separation necessary: decoder give-up, a video-only cut, and old-reader delivery. Static screen → no blind "N seconds no frame reset" watchdog; combine control health, decoder error, age of sent work, liveness keyframe.
- SE5 Sleep: HOST_SLEEP/BYE, disconnect & reconnect to saved IP on wake are real device fixes; reboot, host crash, permission loss, OS update recovery not covered. [C02 C37]
- SE6 Leak/race/deadlock: no unbounded raw-frame list or obvious main-loop deadlock proven. Socket close-once, bounded mailboxes, wake-up/cancel paths, native AAudio single-owner good. "No leak" needs long RSS/FD/thread/native codec count measurement. [C09 C33 C45]
- SE7 Concrete points: encoder submit vs invalidate ownership gap (M02); old decoder thread join unbounded / codec stop/release before output thread exits (M03); old video generation last frame delivery (M01).
- SE8 AAudio dlopen handle kept open intentionally for process lifetime; not a repeating leak. Share close/open and long surface churn should be in measurement matrix.

## p11 Priority table: H01–H05 High, M01–M07 Medium, L01–L03 Low (titles as below). H03 especially high when Wi-Fi primary; H04 lower if tablet is auxiliary screen.

## p12 H01 — Pairing trust boundary (K)
- Problem: ClientHandshake.complete doesn't use stored key for host_id as verification input on KEY_PAIRING reply; only marks rePairing=true. SecureSession.storePairKey writes new key over same host_id. SessionController does this after first HELLO_ACK, before Mac approval and explicit local trust approval on tablet. [C29:61-76 C29:131-149 C10:650-678]
- Why: SAS code only displayed; if other side can produce its own ACCEPTED message it doesn't give mandatory verification. SessionMachine continues with server's accept message. [C30:300-325]
- Attack: active attacker impersonating endpoint/redirecting connection; fake host announcing same host id starts new ECDH pairing → can replace tablet's stored key; if fake acceptance followed by user input/clipboard → reaches fake end. Even without completion, old pairing corrupted → DoS. Doesn't give real Mac's key; passive sniffing insufficient. High not Critical.
- Where: Handshake.kt 61-76, 131-149; SessionController.kt 650-678; SessionMachine.kt 300-325; CryptoVectorsTest re-pairing test accepts replacing old key as expected behaviour → contract must change. [C44]
- Fix: for known host_id, KEY_PAIRING → explicit "Mac identity changed / re-trust" state; don't replace old key immediately; new key in separate pending record; explicit approval on tablet for SAS; atomically persist when both trust decision and protocol accept complete. If connection drops during approval keep pending vs trusted separate (orphan-approval ergonomics kept). Adding a new host must be user-initiated; no input/clipboard/file transfer before comparison complete. Normal PAIRED reconnect silent. "Forget key" explicit user action.
- Acceptance: stored host_id + different ephemeral key + KEY_PAIRING: old key unchanged, input/clipboard off, fake ACCEPTED doesn't activate session without explicit user approval. User-approved real re-pair, drop during approval, cancel scenarios pass. Key/SAS not logged.

## p13 H02 — Decoder give-up only logged (K)
- VideoRenderer.decodeAttempts: when retry budget exhausted → active=false, onGiveUp. MainActivity.installConfig onGiveUp only MbLog.e. syncInputActive looks at activity/panel/viewport not decoder health. [C12:341-353 C17:1147-1155 C17:639-648]
- Impact: screen frozen on last frame/black while keyboard/mouse/pen still go to Mac. Host heartbeat-silence protection doesn't replace this. Frequency on device not measured.
- Fix: video health explicit session sub-state. On terminal decoder error immediately turn off local capture, send RELEASE_ALL, mark frozen image with fault layer. Bounded codec/video reconnect then full session reconnect. Don't open input in new generation until first valid image. Distinguish static screen vs decode failure.
- Acceptance: forced MediaCodec create/configure/dequeue errors → visible error/reconnect state; no stuck key/pen on host; if auto-recovery fails one-tap retry. Prereq for daily main screen.

## p13 H03 — Wi-Fi: app queue bounding not enough (K+N)
- SocketVideoTransport and BSD writable control bound app side, but bitrate/fps/pacing not managed by real age of data accepted by kernel & waiting in network. TransportBitrate = fixed preference/environment setting, not continuous measured adaptation. Changing bitrate preference today requires capture/encoder restart. [C08 C09 C36 C35:369-389]
- NOTES: full-screen changes → video bursts raise control srtt from 20 ms to 60–100 ms, audio underruns same session. Input upstream, audio downstream; shared airtime. [C02:973-989]
- Fix: baseline same content with Mac Ethernet + tablet Wi-Fi, both Wi-Fi, USB. Measure unsent bytes, unacked bytes, RTT change, frame size, receive age. Deadline/age-focused send budget, fast-down slow-up bitrate. Bitrate-only update inside VT session without restart. If needed stream large frame in bounded write chunks (measure that it doesn't empty AP queue alone).
- Acceptance: full-screen motion + pinch + audio → p95/p99 input-to-photon and audio underruns within pre-set budget; growing queue to hide stalls ≠ success. UDP/QUIC only after measurements.

## p14 H04 — Virtual display tied to connection life (K)
- DisplayLease.defaultGraceUs 10,000,000. Session end → grace; expiry → teardown. Android onStop closes control session. So backgrounding app, locking screen, long network outage → virtual display removed. [C34:5-9 C34:58-66 C17:1758-1783]
- Impact: window placement and some apps' render surfaces change; windows move to other displays; placement loss on reconnect. Running capture/encoder during grace wastes resources. [C35:392-405]
- Fix: separate virtual display life from session/capture/encode life. "Keep main display" policy: on disconnect release input, stop media, keep display identity & geometry at low cost. Display removal = explicit user preference, long configurable duration, or host shutdown. Mac menu "remove/recover display" action.
- Acceptance: tablet away 30 s, 5 min, during sleep → desktop placement preserved; idle encoder load doesn't grow. New session: current keyframe first then input opens. If mode/refresh change requires recreation, show expected effect to user.

## p14 H05 — Latency metric doesn't validate product claim (K+N)
- Latency computed at onOutput; excludes AdaptivePacer, SlotReleaser, Surface presentation, panel, whole input path. Host FrameTrace and client captureTimeUs not same origin. 'shown/rendered' counters not equal to physical panel. [C12:497-509 C12:539-573 C15 C16 C04:550-575]
- Impact: good-looking 10 ms can conflict with felt latency; optimise wrong stage; high fps throughput confused with low input-to-photon.
- Fix: rename current value capture-stamp-to-decode-output. Separate real capture origin & presentation PTS on wire. Report decode, pacing, Surface render, input ACK separately. Show clock offset uncertainty & missing callback count. Optical test for whole path. p50/p95/p99 & stall distribution instead of mean.
- Acceptance: single frame ID joins all software stages; negative/contradictory times diagnosed not clamped; residual difference optical vs software explained; separate results 60 & 120 Hz.

## p15 M01 — Video reader doesn't validate session generation at delivery (K+R)
- VideoConn.loop checks hello.configId == currentConfigId at frame delivery but not that reader belongs to currently active connection/session generation. onStreamConfig posted async to UI; onVideoFrame goes from background thread directly to current renderer. [C10:827-843 C17:497-507]
- Impact: frame read into memory can be delivered after old socket closed; same config ID in new session can pass wrong generation check; config not yet applied in UI → new frame to old queue/codec. Short corruption, wasted first keyframe, unnecessary resync. Not claimed every connection.
- Fix: delivery envelope sessionGeneration + videoGeneration + configId; atomic check of active identity in sink. Don't accept frames before new codec/config ready, or keep in separate bounded queue for right generation. Apply audio/clipboard generation discipline to video.
- Acceptance: barrier-stopped old reader at delivery; new session/config activated; old reader released → no frame reaches new renderer. Fast USB/Wi-Fi switch & consecutive config changes recover with first valid keyframe.

## p15 M02 — Encoder reservation and real VT call not under same order (K+R)
- reserveSlot updates inFlight/PTS/keyframe state under lock. encode, flushPending and callback drain paths make the real send/VTCompressionSessionEncodeFrame call after releasing lock. stop also releases lock then calls CompleteFrames/Invalidate. Lock protects state but not lifecycle order of API calls. [C04:312-325 C04:535-579 C04:612-655 C04:659-678]
- Impact: thread takes slot, then stopped; other thread invalidates encoder; first thread tries submit to old session. Two submits may reach different API call order than reservation. Encode error, extra restart, broken ordering assumption. Native crash/memory corruption not proven; VT thread safety doesn't solve logical ordering.
- Fix: single encoder owner queue for submit, property update, flush, invalidate. Callback results carried to owner; avoid sync re-entry deadlock from callback. Keep bounded pending latest-frame logic instead of heavy lock. Stop closes new submits and ends previously owned work defined way.
- Acceptance: controlled barrier between reserve & send → stop/reconfigure race; verify no call to old VT instance after stop. Capture, static-keyframe, flush timer, shutdown raced in same test. Narrow scope after behaviour test.

## p16 M03 — Missing time/ownership contract for decoder teardown (K+R)
- retire waits ~300 ms for old decode thread then continues; new decodeLoop waits unbounded previous.join(). runCodec.finally waits 500 ms for output thread then calls codec.stop/release without requiring it to be dead. [C12:262-270 C12:327-338 C12:482-488]
- Impact: native codec call hangs → new renderer waits forever for old thread. Output thread timeout → close and output access overlap. Thread chain, black screen, or only-app-restart-fixes risk. Not reproduced on real driver.
- Fix: codec life with explicit owner/finalize protocol. Don't hand resource ownership to next generation until in/out workers confirmed done. Budget exhausted → H02 visible safe state. Native call not cancellable → offer app restart; don't pile new threads behind infinite join. Software timeout doesn't magically kill native driver call.
- Acceptance: Surface destroy/create, 100 mode changes, background/foreground, decoder error injection → thread, codec instance, native memory return to baseline; recovery upper bound measured.

## p16 M04 — Pen time intervals & input freshness not carried end-to-end (K+N)
- MotionEvent history times carried in protocol but host handlePen iterates batch.samples sequentially; base/delta times not used for injection rhythm. CGEventPoster doesn't apply original timeline. SendQueue's age limit looks at app queue at new offer; input taken by writer or kernel not visible. [C18 C24 C26:16-23 C27]
- Impact: Wi-Fi-accumulated samples posted on host at very short intervals; position/pressure order kept but brush speed/time-based behaviour & line smoothness change. NOTES: USB regular few-ms intervals vs Wi-Fi clustering & jagged lines. Delayed old click/drag after network stall separate freshness risk. Host silence watchdog doesn't measure age of every old event if data flows regularly afterwards. [C02]
- Fix: make capture-to-injection age visible with sequence & clock field. Hover/relative movement → transition to latest state; define safe release/reset policy for key/button/stroke boundaries. Don't blindly drop active stroke samples. Small hard-bounded timestamp playout experiment for Wi-Fi pen; adopt 8–12 ms only if line quality gain exceeds optical latency cost. Changing CGEvent timestamp alone won't restore OS dispatch rhythm.
- Acceptance: replay recorded pen trace with added burst/stall; position, pressure, stroke boundaries preserved; old input age controlled; no up lost. No unnecessary smoothing latency on USB.

## p17 M05 — Access scope can be narrowed (K)
- BsdTcpListener default production bind dual-stack any; no host profile restricted to loopback even when only USB used. Optional tablet file sharing exposes whole shared external storage root with MANAGE_EXTERNAL_STORAGE. [C09:88-131 C33 C39 C42]
- Impact: pairing/attempt surface wider than needed. Approved Mac can read/modify wider user file area than narrow folder.
- Limit: DAV service bound to loopback, token-protected, opened via USB forward; "tablet files on open Wi-Fi HTTP server" claim is not true. Wide file access is explicit design choice; unauthorised leak not proven. [C39 C40]
- Fix: USB-only, selected LAN interface, automatic LAN profiles; in USB-only close discovery advert & LAN listening. Option: pairing approvals limited to short user window. File sharing: selected folder & read-only scope option, "sharing on" indicator. Keep token refresh, canonical path check, connection limits.
- Acceptance: USB-only profile → ports unreachable from external interfaces; normal USB works. Path/encoding/symlink attempts outside file scope can't access; when sharing closed token/forward/server usability ends. Network attack test on user device authorised separately.

## p17 M06 — Private API & headless recovery should be managed as product boundary (K+R)
- Private CGVirtualDisplay for display, undocumented CGEvent field/type for pinch. Isolation in separate files right. If OS update breaks behaviour & tablet is only screen, big impact. LoginItem SMAppService.mainApp starts at user session; not a pre-login display service or crash supervisor. [C05 C38 C37]
- Impact: first setup permissions, host crash, OS update, reboot, pre-login screen need second access path. Sleep/wake working doesn't cover these. FileVault/preboot behaviour tested separately with user's setting.
- Fix: record supported OS build & app version; short capture/input/pressure/pinch smoke test before update. Private API failure → understandable state & supported physical screen capture fallback. Permission/startup check, manual reconnect, window recovery, local/second remote access runbook. App Store compatibility not mandatory; recovery is.
- Acceptance: host process kill, permission revoke, reboot, login/logout, OS update rehearsal; each has tested steps to reach Mac again. If login item registration fails, first-run flag must not silently block retry. [C37:39-64]

## p18 M07 — Tests strong but platform/soak evidence not reproducible (K+N)
- Pure logic tests broad; protocol fixtures & mutual crypto vectors valuable. No automated CI workflow, no Android instrumentation test tree, no reproducible e2e hardware/long-use result package. Latest performance experiment tools in scratch; NOTES says recreate if lost. [C41 C02:1115-1120]
- Keep: input ownership, owed release, disconnect/reset, key mapping, fuzz & malformed protocol tests; FrameQueue/keyframe request coalescing & pacing trace tests; audio jitter/drift/refill tests.
- Fix: CI: macOS Swift build/test, Linux/suitable runner Android assembleDebug + JVM test, fixture & crypto vector consistency; failure visible for merge. New logic tests: H01 trust transition, H02 terminal decoder state, M01 old reader barrier, M02 submit/stop race, M04 old input orders — test security contract not mirror implementation. Device smoke package: one-command build ID, codec name/properties, panel Hz, mode/bitrate/transport, short trace; don't collect raw input text/clipboard/keys. Replay material: network condition & visual content definitions, anonymised small pacing/input traces & analysis scripts versioned in repo; no large personal raw recordings. Soak: 8 h real work then one week; RSS/native memory, FD, thread, codec instance, reconnect & release success trend.
- Acceptance: each result has commit, host OS, tablet OS, codec, network topology, resolution, target/real Hz, bitrate, test content, duration. Restart-requiring events counted. Same condition ≥3 tries; no cherry-picked good seconds. Tests not run on device explicitly "not run".

## p19 L01 — Docs & build identity don't track real system (K)
- README describes early Phase 0 while code has audio, files, advanced input, streaming. Android versionCode=1, versionName=0.1. [C01 C42 C02]
- Fix: update README with current buildable features, known limits, short recovery steps. Add commit, build date, active experiment profile to About/log start. Specify last verified Mac/tablet version pair. NOTES stays research log; product state single current page.

## p19 L02 — Experiment options complicate daily product path (K)
- MainActivity ~2,100 lines; SessionServer ~1,800 lines. Multiple pacers, GL path, perf hint, crypto/net bench, refresh reflection, many intent/env knobs in same workspace. [C17 C33 C12 C13]
- Fix: first inventory experiments without behaviour change: keep / debug-only / retire. Choose few verified profiles for daily product; log active profile one line. SessionUi, VideoHealth, InputBinding, Settings separable from MainActivity along natural ownership boundaries. No wide refactor before H01–H05 closed. No new production state machine per experiment.

## p19 L03 — Copy & frequent OS query cost should be measured (K+R)
- Compressed frame byte conversion/encryption & MediaCodec input copy; display geometry/CGEventSource/cursor state queries during input injection. Relevant at ~360 Hz pen or high res/fps. [C04 C12:454-472 C27 C32]
- Fix: allocation profiler & stage times to find cost share. Simplify compressed buffer ownership, pools, refresh immutable geometry on display-change event, safe source reuse. Don't remove crypto or bounds checks for performance. Keep T-141/T-142 idle wake-up & diagnostics-off-by-default gains. [C02:1079-1118]

## p20 Simpler architecture
- A1 Three owners: DisplayOwner (fixed display identity, geometry, refresh policy, recovery; lifetime = Mac user session / explicit user preference); SessionOwner (identity, encrypted control, input, release, health; lifetime = trusted connection session); MediaOwner (capture, encoder, video transport, decoder-ready, presentation health; rebuildable media generation). No new framework/DI.
- A2 Keep: native capture/encode/decode + SurfaceView (no WebView/canvas); reliable ordered control + input model protecting edges; latest-frame pre-encode + HEVC-dependency-aware bounded queue post-encode; P-256/HKDF/AES-GCM + pair-key protection + video proof (fix trust workflow); macOS private API isolation; hardware notes, golden fixtures, pure state machines, fuzz tests.
- A3 Don't drop TCP first; Wi-Fi shared airtime doesn't vanish with UDP. First H03 pacing/age/bitrate feedback & Mac Ethernet test. Control/audio separation only if measured control downlink HOL latency benefits.
- A4 Datagram media (QUIC datagram / measured UDP/RTP) only if packet-loss HOL breaks p95/p99 after backlog management improved; must design fragmentation, pacing, loss policy, congestion control, encryption, nonce safety, decoder reference recovery together. Input control can stay reliable.
- A5 Lower perceived latency: local mouse cursor or temporary pen trail; coordinate transform, remote cursor reconciliation, real app line merge care. Optical A/B. Don't send fake predicted pressure/stroke to Mac; local visual feedback only.
- A6 Dynamic quality: first lever bitrate, second content/fps profile, last resolution. Display refresh change recreates display in current impl → not part of fast adaptation. User can pick 60/120 as stable profile.

## p21 Development order (1–5)
- D1 Safe baseline: record build IDs of known good Mac app and APK from current commit; verify USB baseline & second access/recovery path; fix current settings, OS builds, apps in one test profile; no new features. Exit: tested how to reach Mac if host closes / tablet app closes / network goes; commit of installed binary known.
- D2 Close H01: mandatory re-trust on tablet, pending/trusted separation, commit flow preserving old key. First pairing & drop tests. Negative test preventing silent key change = merge gate. Exit: fake KEY_PAIRING/ACCEPTED can't change trusted record nor start input/clipboard.
- D3 Safely stop input on frozen image: tie H02 health state to Session/UI/Input; complete M01 boundary; handle M03 teardown waits; deterministic race test for M02 then narrow fix. Exit: decoder error injection, fast surface change, USB/Wi-Fi switch recover visibly/measurably; no wrong-generation frame/input; no stuck key/pen.
- D4 Decouple virtual display: H04 DisplayOwner, keep-main-display preference, media pause/resume, Mac remove/recover display action. Separate bitrate change from display life. Exit: tablet in other app for minutes doesn't break placement; idle resource use doesn't rise.
- D5 Measurement part of product: H05 & M07; stage traces joined by frame/session ID; fix capture-to-decode name; add Surface & input ACK; optical input-to-photon USB 60/120 baseline; version analysis scripts. Exit: p50/p95/p99, long stalls, real Hz, input quality repeatable; which numbers physical vs software estimate is clear.
- These five before new codec/transport/big refactor.

## p22 Development order (6–10)
- D6 Wi-Fi topology & controlled flow: same recorded workload over USB, Mac Ethernet + tablet Wi-Fi, both Wi-Fi. H03 age/byte budget, video write pacing, in-session bitrate update. Full-screen motion with audio. Check fixed conservative Wi-Fi profile first. Exit: acceptable tail latency & audio dropouts beside good mean; no seconds-old image/input replay after short stall; if loss-driven latency still dominant → small datagram video experiment.
- D7 Validate pen per app: Krita dot, fast/slow curve, pressure ramp, tilt directions, hover, eraser, drag, palm scenarios recorded. M04 timestamp replay/age policy measured. Wi-Fi smoothing only if quality gain & total latency target kept; USB stays lowest-latency profile. Exit: short real dots not lost; no ghost click/stroke; no up loss; tilt/pressure consistent; clear finger-navigation vs drawing policy.
- D8 Fix few power & quality profiles: e.g. "Text / 60", "Fluid interaction / 120 where suitable", "Wi-Fi balanced". Full res for text; don't render 120 when panel 60. Check hardware actually selected & thermal throttling. Document SDR limit with colour test patterns & thin text. Exit: profile change reliable; active/real Hz visible; no unnecessary CPU/GPU spike; experiment options don't fill daily settings screen.
- D9 Simplify network/file scope & setup: M05 USB-only/LAN scope; narrow file permission; permission & login startup check; one-page setup/run/recovery flow. README/build ID & supported version pair updated. Factory/known-good profile reset for all settings.
- D10 One week real workload resilience: daily editor/browser/terminal/drawing, audio, occasional file copy; overnight sleep, network & USB switching during day. First 8 h soak then ≥1 week. Count restarts, input release errors, long frame gaps, memory/thread/FD trend. Exit: no unexplained growing resource use, stuck input, blind input, unrecoverable freeze.
- Use exit conditions, not calendar.

## p23 Acceptance & fault-injection matrix (each row)
- X1 Trusted host re-pair: fake host_id/KEY_PAIRING, cancel, drop, real re-approve → key stays old; input/clipboard not opened without approval.
- X2 Key & pen release: Shift/Ctrl+drag while pulling USB, Wi-Fi off, app background → no ghost down; close time, owed release count.
- X3 Video terminal error: codec create/configure/dequeue error injection → visible health state, RELEASE_ALL, bounded retry.
- X4 Old reader race: old frame delivery released by barrier after new session → zero old frames to new renderer.
- X5 Encoder shutdown race: barrier between reserve/send; stop or reconfigure → no submit after invalidate; deterministic.
- X6 Surface churn: 100 fg/bg, mode & Surface changes → thread/codec/native memory back to baseline.
- X7 Display continuity: 30 s / 5 min outage; host sleep → window placement preserved; reconnect time measured.
- X8 Wi-Fi stress: full-screen pan/scroll, pinch + audio; USB/Ethernet/Wi-Fi same content → RTT, unacked, queue age, p95/p99, underrun & resync.
- X9 Pen accuracy: corners, pressure ramp, four tilt directions, hover/eraser, palm → coordinate drift, lost dot/stroke, ghost click.
- X10 Keyboard/mouse: Turkish Q/ISO, modifier, repeat, pointer capture, device removal → mapping accuracy, focus & release result.
- X11 Image quality: thin coloured text, B/W ramps, moving pattern → chroma/range/gamma, readability & bitrate.
- X12 60/120/144 Hz: target Hz vs real panel tracked separately; content types separated → real presentation rhythm; unsupported target reported clearly.
- X13 Soak/recovery: 8 h + 1 week; host kill/reboot/permission loss → restart need, RSS/FD/thread trend, access runbook.
- B1 Proposed starting budgets (not results): optical USB pen input-to-photon p95 < 45 ms; at 120 Hz reduce long presentation gaps during motion separately; Wi-Fi first budget p95 70 ms, re-evaluate with loss & drawing feel; p99 & stalls reported separately. Few seconds target to return to visible current image after single disconnect; backoff & wake paths separate; sleep, cold boot, codec-native hang not same SLA. Input safety target: zero stuck key/pen, zero wrong-generation delivery; don't hide errors in averages. Static screen low FPS normal; target consistent cadence in motion, fast first-interaction response, low idle power.

## p24 Final
- F1 Strengths to protect: stylus pressure/proximity/ownership, input release safety, reference-dependent frame queue, pairing, real device issues in one system; pure state machine separation & measure-on-device-and-revert habit (T-144 revert good example).
- F2 Must be redesigned (narrow, not rewrite): display lifetime from session; video health from TCP connection; trusted key from pending pairing; explicit resource ownership & generation contract for encoder/decoder.
- F3 Simpler: reduce daily path to few verified profiles; experiment modes to debug area; DisplayOwner/SessionOwner/MediaOwner. Don't remove keyframe gate, release latches, encrypted handshake.
- F4 Level today: personal beta; not proven as long-term sole main screen without recovery; Wi-Fi drawing timing/network work; trust flow risk; codec failure input health gap.
- F5 Decision: USB reference, second access path ready; fix trust approval, input stop on image fault, persistent display life first; then real e2e measurement, then re-evaluate wireless with Mac Ethernet + tablet Wi-Fi; pen quality, energy, colour later. Before daily main-screen acceptance: validation for all H01–H05, race/freshness tests for M01–M04, setup-recovery runbook, ≥1 week usage evidence. New transport/full refactor not at top.

## Addendum (from the coverage audit) — points not itemised above
- O1 (p2, p24) Review is static + repo notes; no performance test on Mac/MatePad; not a code change or performance certificate; absence of Critical not guaranteed.
- O2 (p3) Scope: personal Mac mini + MatePad use; multi-user cloud, App Store, general Android compatibility not targets.
- O3 (p3) Reviewer did not run scripts/check.sh, Swift/Android builds or Swift crypto-vector generation; only gen.py --check + fixture-name match. Tests passing not claimed.
- O4 (p4) Mac app runs in user session; VT encodes "mostly" HEVC (H.264 path exists).
- O5 (p4) Thread map conclusion: single thread adds latency; more threads not the fix; simplify lifecycle of time-sensitive resources and generation ownership of outputs.
- O6 (p5) Video table load notes: queueDepth=5 ≠ 5 frames delay; replacing raw frame pre-encode doesn't break HEVC chain; kernel write ack ≠ peer received/displayed; large frame / lost segment HOL-delays following bytes; showing a newer output after decode is possible.
- O7 (p6) Frame periods 16.67 / 8.33 / 6.94 ms; a missed present slot costs one period.
- O8 (p6) Input ACK ≠ target app processed the event; 240 fps video ≈ 4.17 ms resolution, needs no clock sync.
- O9 (p7) Platform may not apply unbuffered dispatch identically → keep history support.
- O10 (p8) Higher tilt resolution in protocol can't create samples the source never produced.
- O11 (p8) Don't unconditionally suppress every finger event; breaks daily use.
- O12 (p11) For R-tagged findings (M01, M02, M03, M06, L03) the first job is a deterministic failure scenario.
- O13 (p11) High also covers usage/verification gaps blocking the daily main-screen goal; USB-heavy drawing reduces H03; H04 lower if tablet is auxiliary.
- O14 (p18) Expensive bugs are OS/driver behaviours; pure tests model but can't verify; track failure contracts not test counts.
- O15 (p19) L03 not proven to be biggest bottleneck; not ahead of Wi-Fi and render health.
- O16 (p19) L01 impact: hard to know which fix an APK contains; old "ceiling" notes taken as product truth.
- O17 (p20) No proven benefit from WebView/canvas image path; a separate socket alone gives no Wi-Fi priority.
- O18 (p13, p14) H02: user may type into an invisible window / drag in wrong place. H05: not an honesty accusation; missing metric contract. H01: "Mac forgot the key" vs fake host not separated as a blocking trust decision.
