# gpt-6-astra (high) — mimari sadeleştirme ve yapısal performans, 2026-10-08

Kullanıcı onayıyla (2026-10-08, T-297). Codex `gpt-6-astra`, `model_reasoning_effort=high`, salt okuma, `main` @ `3acaa874`. İstem: `T-297` kartının Yöntem 2. maddesi. Aşağıdaki metin modelin çıktısıdır (değiştirilmedi). Triyaj: `simplification.md`.

---

**MateBridge’s complexity budget now goes mainly into lifecycle coordination, recovery, and optional media paths—not the basic LAN transport.** The best simplifications are retiring completed experiments, reducing duplicated transition logic, and moving test reference implementations out of production. The clearest remaining structural performance opportunity is reducing full-frame copies across encoding, serialization, decryption, and decoding.

Reviewed **`3acaa8741fd61cd3700d3b579d0bfa4b4fc8bfa5`**, read-only. The fixture generator’s `--check` passed. Builds, unit suites, and hardware measurements were not run. Size estimates below are approximate; “moved” lines do not represent a smaller repository.

Findings are ranked by expected value relative to risk.

1. **S1 — Finish retiring experiments that still reach lifecycle code**

   **Evidence:** The tablet Wi-Fi controls remain in [WifiKnobs.kt:12](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/WifiKnobs.kt:12), including a lock policy/backend/holder at line 96. They require Activity setup and lifecycle synchronization in [MainActivity.kt:404](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:404), plus control/video socket branches at [SessionController.kt:831](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt:831) and line 1028. `KNOBS.md` records the T-127 removal decision; the measured negative result is in [NOTES.md:1330](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:1330).

   The later 60 Hz experiment likewise retains reflection, platform hints, and touch-triggered reapplication: [HzPin.kt:10](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/stream/HzPin.kt:10), [MainActivity.kt:840](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:840), and line 1818. Its negative result is recorded at [NOTES.md:1393](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:1393).

   **Do:** Remove `tos_ctl`, `tos_video`, `wifi_ll`, and their lifecycle plumbing. Retain `ping_ms`, RTT statistics, and `TrafficClass.trySet`: Wi-Fi file connections still use the latter at [SessionController.kt:702](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt:702). Separately retire `hz_pin` after recording that decision; retain ordinary display-mode selection, `setFrameRate`, and refresh measurements.

   **Size/risk:** Approximately **300–450 production lines** plus obsolete tests removed. Low risk to normal operation. Removing these intentionally changes developer-extra behavior; it is not equivalence for every launch argument.

   **Proof:** Update `DevKnobsTest` and `WifiKnobsTest`; retain file-traffic-class coverage. Compare default launch, USB/Wi-Fi migration, backgrounding, and Game60↔Daily display behavior on-device.

   **Hot path:** Mostly lifecycle; `hz_pin` also intersects touch handling. **Protocol:** No wire change.

2. **S2 — Complete the production/test boundary cleanup**

   **Evidence:** The October 7 `FrameQueue.poll()` and Kotlin `ChromaReuseModel` findings have been addressed. Other reference implementations remain:

   - Swift CPU packing/unpacking and plane types occupy [PackedChroma.swift:3](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/PackedChroma.swift:3) through line 130. Production callers use the size predicate and Metal kernel, not CPU packing.
   - CPU image conversion/reconstruction remains in [SharpYUV.swift:38](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/SharpYUV.swift:38). Production needs its upsampling enum and EOTF table, used by [ChromaConverter.swift:62](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/ChromaConverter.swift:62).
   - Kotlin `Avc444v2.home` and `YuvConversion.toRgb` are reference calculations at [Avc444v2.kt:29](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/Avc444v2.kt:29) and line 58; production uses size validation and conversion uniforms.
   - The retired in-flight limiter survives as `canQueue`, `STALL_NS`, and `onHeld` at [SlotReleaser.kt:134](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/SlotReleaser.kt:134). Its callers are tests, including [PresentationSchedulingTest.kt:105](/Users/burakakcan/Desktop/matebridge/client-android/app/src/test/kotlin/dev/matebridge/client/video/PresentationSchedulingTest.kt:105).

   **Do:** Move CPU reference calculations into test support, retaining runtime constants, validators, uniforms, and shader sources. Delete the obsolete limiter API, its unused timestamp bookkeeping, and tests of that removed feature. Keep the in-flight occupancy metric.

   **Size/risk:** Roughly **300–350 lines moved out of production**, plus **40–80 lines deleted** across production/tests. Low behavior risk; little expected runtime benefit beyond removing unused bookkeeping.

   **Proof:** Preserve `SharpYUVTests`’ GPU comparison, `PackedChromaLayoutTests`, `Avc444v2Test`, `ChromaReuseTest`, and occupancy percentile tests. Do not replace independent reference calculations with calls to the implementation under test.

   **Hot path:** Reference models: no. Gauge bookkeeping: yes. **Protocol:** No change.

3. **S3 — Use one sender implementation for ordinary and packed video**

   **Evidence:** [VideoSender.swift:103](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/VideoSender.swift:103) implements the packed loop with queue activity notifications and `tryPop`; [VideoSender.swift:193](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/VideoSender.swift:193) implements a second ordinary loop with `frames.next()`. Conversion, timestamps, transport completion, failure handling, and counters are repeated between `write` at line 166 and the ordinary loop at line 210.

   **Do:** First share the write/completion implementation. Then represent ordinary video as the main-only case of the same sender loop: one bounded wake signal, main-first selection, optional auxiliary arbitration, and per-view sequence counters. Keep packed-specific pairing/drop policy explicit.

   Do **not** delete `VideoFrameQueue.next()` wholesale: production draining and the dump tool still use it at [StreamCoordinator.swift:1183](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:1183) and [VideoDump.swift:108](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoDump.swift:108).

   **Size/risk:** Approximately **40–90 net lines removed**. Medium risk around wakeups, cancellation, and config-before-keyframe ordering. This removes parallel implementations; it does not establish a throughput gain.

   **Proof:** Run `VideoSenderTests`, `PackedSenderTests`, `BsdTcpSocketTests`, and keyframe-resynchronization tests. Exercise empty queue, blocked socket, failure while awaiting a frame, cancellation, reconnect, and auxiliary-without-main cases against both modes.

   **Hot path:** Yes, every encoded frame. **Protocol:** No change; preserve sequence assignment and view semantics exactly.

4. **S4 — Collapse host frame serialization copies**

   **Evidence:** Each encoded sample is copied from `CMBlockBuffer` into an array, then converted into a second Annex-B array at [HEVCEncoder.swift:1073](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift:1073). [AnnexB.swift:5](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/AnnexB.swift:5) builds that new array.

   Sending then materializes a checked message payload, copies it into `Data(type || payload)`, encrypts, and copies ciphertext/tag into the outbound array: [Records.swift:38](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Crypto/Records.swift:38) and line 61. These are explicit byte construction operations, not merely Swift copy-on-write assignments.

   **Do:** Convert the sample directly into its owned Annex-B storage without the intermediate raw array. Add a checked encoding operation that writes `type || payload` directly into the plaintext buffer consumed by the sealer. Preserve one owned immutable frame at the asynchronous boundary; do not let sample-buffer pointers escape their lifetime.

   **Size/risk:** Approximately **150–300 lines changed** across byte writing, sealing, and encoder output. Medium risk. Two full-payload construction passes are concrete removal targets; CPU/latency gains require measurement.

   **Proof:** `AnnexBTests`, codec fixtures, `CryptoVectorTests`, and `BsdTcpSocketTests`; add byte-for-byte comparison of old/new sealed records and segmented `CMBlockBuffer` coverage. Measure allocations and capture→write timing at identical bitrate/content.

   **Hot path:** Yes, including both packed views. **Protocol:** Serialization implementation changes, **wire format does not**.

5. **S5 — Remove the client’s intermediate plaintext copy before considering buffer pooling**

   **Evidence:** The improved direct AEAD path still performs:

   `directOut → scratch ByteArray → VideoFrame.data → MediaCodec input`

   The first copy is [Records.kt:183](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt:183); message decoding copies frame bytes at [Codec.kt:455](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/protocol/Codec.kt:455); codec submission copies them again at [VideoRenderer.kt:715](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:715).

   **Do:** Parse authenticated plaintext directly from a bounded `ByteBuffer` view, then copy the video payload once into its queue-owned array. Share field validation with the existing reader. Keep the owned frame array initially: passing the opener’s reusable buffer into `FrameQueue` would introduce lifetime hazards.

   This targets a remaining copy after T-285/T-292, not the already-removed legacy AEAD arm.

   **Size/risk:** Approximately **150–300 lines changed**. Medium risk in parser bounds and buffer reuse. Removes one plaintext-sized copy per received record on the migrated path; does not remove the MediaCodec submission copy or guarantee lower latency.

   **Proof:** `RecordReceiveAllocTest`, `RecordAeadPathTest`, `RecordOutputSizeTest`, `RecordOpenTest`, crypto/codec fixtures, and queue ownership tests. Retain frames across subsequent decrypts to prove independence. Include fragmented/coalesced reads, bad tags, trailing fields, and maximum sizes.

   **Hot path:** Yes, every video record. **Protocol:** Decoder implementation changes only; preserve all existing bytes and rejection rules.

6. **S6 — Give client video-output lifecycle one owner outside `MainActivity`**

   **Evidence:** The Activity currently chooses direct versus packed output, owns deferred attachment, handles packed failure, constructs/reconfigures the renderer, and advances recovery:

   - Output selection and deferred ownership: [MainActivity.kt:1403](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:1403).
   - Configuration installation: [MainActivity.kt:1516](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:1516).
   - Timed-out teardown reaping and deferred attachment retry inside the statistics/keyframe ticker: [MainActivity.kt:1956](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:1956).

   Meanwhile, `VideoRenderer` independently owns surface attachment, retirement, and codec generations at [VideoRenderer.kt:324](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:324).

   **Do:** Extract a concrete, main-thread-owned video-output controller containing `streamConfig`, renderer/pipeline ownership, `directDeferred`, config installation, and recovery commands. Give it explicit surface/config/foreground events and callbacks for health, installed config, and fallback preference requests. Keep Views, permission UI, and input routing in the Activity. Move teardown reaping with the lifecycle owner, rather than hiding it in a statistics ticker.

   **Size/risk:** **300–450 lines relocated**, little immediate net deletion. Medium–high risk because ordering matters. The benefit is one reviewable ownership boundary, not merely a shorter Activity.

   **Proof:** `DecoderLifecycleTest`, `DecoderTeardownTest`, `GenerationHandoffTest`, `PackedRendererTest`, and `VideoHealthTest`, plus new controller-level tests for packed→direct transitions while teardown is delayed. Device-test surface loss, backgrounding, mode changes, and held-input release.

   **Hot path:** Lifecycle, not per-frame processing. **Protocol:** No wire change; preserve config-install delivery barriers.

7. **S7 — Centralize host configuration commits while retaining distinct fallback policies**

   **Evidence:** Normal preference application derives settings, mutates the active session, increments `configID`, announces, and changes the lease at [StreamCoordinator.swift:487](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:487). HDR, packed-color, and game-display fallback repeat this transaction at [StreamCoordinator.swift:991](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:991), line 1018, and line 1043.

   T-289 already fixed the previously reported HDR runtime fallback gap. The remaining finding is duplicated transition machinery.

   **Do:** Introduce one concrete configuration-commit operation: install effective settings, advance the config ID, announce once, then execute the appropriate lease action. Keep fallback decisions separate: HDR/game-display process latches and packed-color retry-on-mode-change have different semantics. Preserve preference persistence rules and queued-start revalidation at [StreamCoordinator.swift:381](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:381).

   **Size/risk:** Approximately **150–250 lines touched**, **40–80 net lines removed**. Medium risk; avoid replacing these policies with a generic fallback framework.

   **Proof:** `StreamPrefsTests`, `HDRTests`, `GameDisplayTests`, `FullChromaPolicyTests`, and lease/integration tests. Add transaction-order assertions covering “announce before rebuild,” one config increment, retained user preference, and simultaneous disabled capabilities.

   **Hot path:** No; settings/recovery. **Protocol:** No format change, but protocol-visible sequencing must remain identical.

8. **S8 — Consolidate client file-session state instead of mirroring it through the UI**

   **Evidence:** `SessionMachine` owns the file-open request and derives tunnel eligibility at [SessionMachine.kt:649](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt:649). `FilesSessionGate` separately stores connection/config generation, connected state, the same open request, and request ID at [FilesLifecycle.kt:23](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesLifecycle.kt:23).

   The synchronization round trip is concrete: when permission/sharing changes, the Activity clears its gate and tells the session machine to forget the corresponding request at [MainActivity.kt:2215](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:2215).

   **Do:** Extract file-session negotiation from `SessionMachine` into one session-thread-owned component. Feed it explicit authenticated-config-installed, foreground, permission/sharing, and server-scope events. Publish immutable, generation-tagged desired server/tunnel state to the executors. Eliminate duplicated open-request authority; retain generation validation at asynchronous boundaries.

   **Size/risk:** Approximately **200–350 lines reorganized**, perhaps **50–100 net lines removed**. High risk relative to the saving; do this after the earlier items.

   **Proof:** `FilesNetMachineTest`, `FilesLifecycleTest`, `FilesTunnelTest`, and migration/trust tests. Preserve stale-READY rejection, request replacement, USB/Wi-Fi scope separation, and no sharing before authenticated configuration installation.

   **Hot path:** Session transitions, not file-byte forwarding. **Protocol:** No change.

**Things that look removable but must stay**

- **The encoder’s serial submission owner.** Capture already calls the encoder directly at [VideoPipeline.swift:181](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift:181). The queue in [EncoderSubmitOrder.swift:115](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift:115) orders submissions, bitrate changes, and invalidation. Removing it would undo a safety invariant.

- **Separate decoder input/output handling and generation ownership.** Output is drained independently to avoid waiting behind input operations at [VideoRenderer.kt:644](/Users/burakakcan/Desktop/matebridge/client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoRenderer.kt:644). The more event-driven output experiment increased measured latency; its rejection is recorded in [NOTES.md:1710](/Users/burakakcan/Desktop/matebridge/docs/NOTES.md:1710). Keep retirement, queue ownership, and bounded handoff checks.

- **The packed-color GL path.** It implements the accepted full-color feature, not the retired T-018 GL presentation experiment. [Decision 0034](/Users/burakakcan/Desktop/matebridge/docs/decisions/0034-full-chroma-packed-444.md:21) requires the second stream and merge path.

- **Different host/client queue policies.** Host overflow can request a new encoder keyframe; the client must preserve compressed-frame dependencies while catching up. Their differences are specified in [PROTOCOL.md:689](/Users/burakakcan/Desktop/matebridge/docs/PROTOCOL.md:689). A shared generic “latest frame” queue would erase necessary distinctions.

- **Small hardware/test interfaces.** `CompressionBackend`, `DecoderCodec`, and `VideoTransport` support meaningful ordering and failure tests. One hardware implementation alone is insufficient reason to inline them.

- **Independent Swift/Kotlin protocol validation and golden-vector suites.** These are deliberate cross-language checks. Replacing them with one implementation’s round-trip tests would weaken byte-compatibility assurance.

- **Input release/watchdog/rearm state, authenticated-session gates, and `VirtualDisplay` isolation.** These are safety and privacy boundaries, not duplication to remove. The file-state consolidation above must preserve their protections.

- **Still-authorized diagnostic paths.** Fixed jitter 1–2 remains explicitly retained by [decision 0026:48](/Users/burakakcan/Desktop/matebridge/docs/decisions/0026-experiment-knobs.md:48); frame traces, fault injection, and benchmark code have real users. `ImageQuality`, for example, is called by [SharpnessBench.swift:399](/Users/burakakcan/Desktop/matebridge/host-mac/Sources/MateBridgeHost/Video/SharpnessBench.swift:399), so it is not test-only.

None of these recommendations requires a wire-format change. Any subsequent proposal that does change messages remains orchestrator-only work with protocol documentation and fixtures updated together.