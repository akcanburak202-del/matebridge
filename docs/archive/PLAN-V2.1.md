# MateBridge — PLAN V2.1

**Status:** Execution-ready planning baseline — targeted product and input refinement  
**Date:** 2026-08-27  
**Source reviewed:** `MateBridge-PROJECT-DRAFT.md`, `MateBridge-PLAN-V2.md`, and the shared MateBridge design conversation  
**Primary target:** One Apple Silicon Mac + one Huawei MatePad Pro + Huawei keyboard/trackpad + one M-Pencil  
**Primary product goal:** Transform the target MatePad into a native-feeling workstation terminal for the target Mac: display, keyboard, trackpad, touch, and M-Pencil operate as one coherent, low-latency session over USB first, then supported headless, LAN, and remote paths.  
**Revision principle:** Plan V2's evidence-first milestone order remains authoritative. V2.1 refines product identity, physical-input validation, experience-profile naming, and stylus-oriented experiments without pulling speculative features into the critical path.

---

## 0. Executive Decision

The original draft has the correct product instinct but too many overlapping phases, hypotheses, architecture candidates, and long-term goals in one document. Plan V2 fixed the order in which uncertainty is removed. Plan V2.1 preserves that order and makes the product target more precise: MateBridge is not merely a remote display. It is a coherent workstation terminal built from the MatePad display, Huawei keyboard/trackpad, touch surface, and M-Pencil.

MateBridge should be developed in this order:

1. Prove the platform blockers, including the real Huawei keyboard/trackpad event path.
2. Establish one fully instrumented video-first vertical slice.
3. Make the `DESKTOP_FULL` USB experience stable enough for a real coding session using the MatePad's own keyboard and trackpad.
4. Make post-login headless operation reliable.
5. Improve stylus fidelity and run a bounded `PEN_DISPLAY` spike.
6. Test interaction-aware display scheduling as a stylus-latency hypothesis.
7. Test the adaptive tile/region/video thesis with reproducible workloads.
8. Implement only the optional optimizations that pass their frozen gates.
9. Add LAN.
10. Add secure Internet access.
11. Productize only the parts that survived measurement.

The project must not freeze a sophisticated architecture before five questions have concrete answers:

- Can the target Mac produce a stable capturable display in the exact monitor/headless states required?
- Can the exact MatePad and M-Pencil expose useful stylus samples?
- Can those samples be injected into macOS applications with sufficient fidelity?
- Does the exact Huawei keyboard/trackpad expose enough key, pointer, drag, and scroll fidelity for daily use?
- Can a practical USB path carry display, input, control, and metrics with reliable reconnect behavior?

The original adaptive-display thesis remains valuable, but it is a **gated optimization hypothesis**, not the foundation on which the first usable version depends. `PEN_DISPLAY`, local ink, and interaction-aware scheduling are also experiments with explicit rejection paths, not promises hidden inside the local MVP.

## 0.1 V2.1 change boundary

V2.1 intentionally keeps the Plan V2 backbone intact. It adds only the following execution-relevant refinements:

1. The product contract is reframed as a native-feeling workstation terminal rather than a display-only bridge.
2. `DESKTOP_FULL` and `PEN_DISPLAY` are defined as **experience profiles**, separate from transport, display policy, and quality policy.
3. The Huawei keyboard and trackpad receive an M0 capability probe and become part of P2 acceptance.
4. The input plane gains explicit reliable-state, real-time pointer, and real-time stylus lanes.
5. `PEN_DISPLAY` and interaction-aware display scheduling enter M6 as bounded experiments with measurable promotion gates.

V2.1 does **not** move 90/120 Hz, generic device support, automatic adaptive display policy, custom USB infrastructure, or local ink prediction earlier. Video remains the mandatory baseline and tiles still have to earn their production complexity.

---

# 1. Review of the Original Draft

## 1.1 What should remain unchanged

The following decisions are strong and should remain foundational:

- The initial hardware target is intentionally narrow.
- USB is the first transport.
- LAN and Internet are later transports behind the same logical session contract.
- Stylus is a first-class objective.
- Screen transport, input, control, and metrics are separate channels.
- Every performance claim requires measurement.
- Tile transport must compete against a strong hardware-video baseline.
- 60 Hz must be made excellent before 90/120 Hz work begins.
- Internet access is blocked until authentication, encryption, and threat modeling are ready.
- Experimental code stays isolated until evidence justifies promotion.
- Existing working subsystems are not rewritten without a measured reason.

These principles are the strongest part of the draft and should become enforced repository rules rather than advisory text.

## 1.2 What should be changed

### A. Replace duplicate phase systems with one canonical milestone graph

The draft currently contains both a long sequence of phases and a second milestone sequence. This invites drift: tasks can move in one list but not the other. Plan V2 has one dependency graph and one detailed milestone definition per stage.

### B. Split “MVP” into product maturity levels

“First pixels,” “interactive prototype,” “daily driver,” and “headless primary screen” are materially different products. They need separate acceptance gates.

### C. Move platform blockers to the beginning

The original plan correctly identifies virtual-display, stylus, USB, and headless risks, but some are validated too late. Headless operation is central to the actual Mac mini use case, so its **feasibility** must be tested in M0 even though its polished implementation comes later.

### D. Test both ends of the stylus path

An Android stylus diagnostic proves only the source side. It does not prove that macOS applications will receive pressure, tilt, hover, button, or proximity in a useful form. Plan V2 therefore adds an early macOS input-injection probe and a small target-application matrix.

### E. Treat permissions and distribution as architecture inputs

Screen capture, event posting, launch-at-login, signing, app identity, and any restricted entitlement affect the product lifecycle. They must not be deferred to installer work. The exact development and distribution mode is recorded in M0.

### F. Add a session state machine

A remote display product is not only an encoder and decoder. It is a lifecycle system. Discovery, permission failure, pairing, negotiation, streaming, degradation, reconnect, sleep, lock, crash, and upgrade states need explicit behavior.

### G. Add queue and recovery semantics

Low latency is often lost through hidden buffering rather than codec speed. Every queue must be bounded, observable, and have a documented drop or recovery rule.

### H. Add deterministic workload replay

The draft lists useful benchmark scenarios, but not a reproducible harness. Plan V2 requires test manifests, fixed workloads, raw trace capture, repeated runs, and generated reports before optimization decisions are accepted.

### I. Add a failure-injection matrix

Cable removal, screen sleep, Mac lock, app backgrounding, notification interruption, permission revocation, decoder reset, resolution change, process crash, and network degradation are normal lifecycle events, not edge cases.

### J. Add a single-writer AI workflow

Multiple agents should not independently reshape the same subsystem. Each task receives a bounded task packet, one implementation owner, one independent reviewer, explicit allowed files, evidence requirements, and rollback conditions.

### K. Reframe the product around one coherent workstation session

The target user experience is not satisfied by pixels alone. The MatePad display, Huawei keyboard/trackpad, touch surface, and M-Pencil must behave as one coherent Mac session. This changes acceptance tests more than it changes architecture: P2 must be usable without an external keyboard or mouse during the supported session.

### L. Separate experience profiles from transport and display policy

`DESKTOP_FULL` and `PEN_DISPLAY` describe what the user is trying to do. USB/LAN/Internet describe how packets travel. VIDEO/REGION/TILE/AUTO describe how pixels are represented. MAXIMUM/BALANCED/DATA_SAVER describe user quality intent. These axes must not be collapsed into one ambiguous “mode” field.

### M. Validate the exact Huawei keyboard and trackpad in M0

A generic Android keyboard test is insufficient. The exact keyboard cover and trackpad must be measured for key codes, text output, modifiers, repeat, Turkish layout, pointer semantics, click/drag, vertical and horizontal scrolling, and Android gesture interception.

### N. Keep Pen Display and pen-aware scheduling behind evidence gates

A focused drawing profile and stylus-priority display updates are promising, but neither is assumed to improve latency. They begin as M6 experiments, retain `DESKTOP_FULL` as a safe fallback, and enter production only after reproducible support and latency evidence.

## 1.3 What should be removed from the active plan

The following items should not disappear forever, but they should leave the active execution path until their prerequisites exist:

- AV1 evaluation
- 90/120 Hz
- HDR and wide color
- multiple displays or multiple clients
- audio, microphone, clipboard, file transfer, drag-and-drop
- a monthly data-budget UI
- automatic NAT traversal and relay infrastructure
- per-region mixed codecs inside one frame
- custom low-level USB infrastructure
- generic Windows/Linux/iPad support
- polished consumer onboarding before the local daily-driver path is stable
- local ink prediction as a promised feature

They belong in a deferred backlog with entry criteria, not in current milestone scope.

---

# 2. Product Contract

## 2.1 North-star experience

MateBridge transforms the target Huawei MatePad Pro into a native-feeling workstation terminal for the target Apple Silicon Mac. Within the declared supported state:

1. The Mac user session is available.
2. MateBridge Host is running or starts automatically.
3. MateBridge Client opens on the MatePad.
4. The trusted devices reconnect.
5. The selected Mac experience appears on the MatePad.
6. The MatePad display, Huawei keyboard/trackpad, touch surface, and M-Pencil participate in one coherent session.
7. Pointer, click, drag, scroll, keyboard, touch, and declared stylus fields behave according to the tested support matrix.
8. A temporary transport interruption recovers without restarting both devices and without leaving held input state behind.
9. Diagnostic information is available when recovery fails.

The daily-driver target is not met by display FPS alone. A representative work session must be possible with the MatePad screen and its tested Huawei keyboard/trackpad, without relying on an external keyboard or mouse during normal supported operation.

## 2.2 Product axes and naming

MateBridge has four independent product axes. They are represented separately in protocol negotiation, configuration, diagnostics, benchmarks, and UI.

### Experience profile

Describes the user-visible workspace and input priority:

- `DESKTOP_FULL` — the full Mac desktop or MateBridge display; primary P2 daily-driver profile.
- `PEN_DISPLAY` — a selected application/window group or dedicated display surface optimized for M-Pencil work; experimental until the M6 gate passes.

The experience profile never switches automatically merely because content changes. Losing the selected `PEN_DISPLAY` source falls back to a defined safe state rather than silently showing the wrong content.

### Transport

Describes how the session travels:

- `USB`
- `LAN`
- `INTERNET`

### Display policy

Describes how authoritative pixels are represented and scheduled:

- `VIDEO`
- `REGION`
- `TILE`
- `AUTO`

`AUTO` exists only after M7/M8 evidence. Before that, the system uses the explicitly selected proven policy.

### Quality policy

Describes user intent and resource/data tradeoffs:

- `MAXIMUM`
- `BALANCED`
- `DATA_SAVER`
- `EXTREME_DATA_SAVER`

Low-level display policy may remain hidden from normal users while still appearing in diagnostics. “Mode” should not be used without naming the axis.

## 2.3 Product maturity ladder

| Level | Name | User-visible meaning |
|---|---|---|
| P0 | Lab Proof | Developer-only first pixels and device/input diagnostics; manual setup is acceptable. |
| P1 | Interactive USB Alpha | Display plus basic input over USB; suitable for short controlled sessions. |
| P2 | Local Daily-Driver Beta | `DESKTOP_FULL` coding/productivity sessions using the tested Huawei keyboard/trackpad, with reconnect, permissions, diagnostics, and lifecycle recovery. |
| P3 | Supported Headless Beta | The MatePad is the normal display after the declared startup boundary; no permanent monitor is required during supported operation. |
| P4 | Adaptive Local | Approved video/region/tile display policies provide measured benefit without visible policy-transition defects. |
| P5 | LAN Beta | Secure and comfortable same-network use. |
| P6 | Remote Beta | Secure different-network access with adaptive data use and explicit limitations. |

Experience profiles are orthogonal to maturity. `PEN_DISPLAY` may be experimental or supported at a given local product level only when its own M6 support and promotion gates pass. No milestone may describe itself as “MVP complete” without naming the product level and supported experience profile.

## 2.4 V2.1 local MVP

The first useful product target is **P2 Local Daily-Driver Beta** in the `DESKTOP_FULL` experience profile, not merely first pixels.

It supports:

- one Apple Silicon Mac
- one exact macOS version range selected in M0
- one Huawei MatePad Pro model
- the exact tested Huawei keyboard/trackpad accessory
- one landscape orientation
- one active MateBridge display/session
- SDR, 8-bit output
- one or a very small set of tested resolution profiles
- USB transport
- one logged-in macOS user session
- pointer motion, click, drag, and a tested vertical/horizontal scroll contract
- physical keyboard down/up, tested modifiers, repeat, shortcuts, and Turkish layout behavior
- touch mapping
- basic stylus position and button state
- pressure/tilt only where M0/M6 evidence proves support
- structured diagnostics
- a daily-driver acceptance run without an external keyboard or mouse

It explicitly does not promise:

- cold-boot pre-login viewing
- FileVault pre-boot control
- every macOS application accepting stylus pressure/tilt
- complete MacBook-equivalent multi-finger trackpad gestures
- production `PEN_DISPLAY` support before M6 passes
- wireless or Internet access
- 120 Hz
- HDR
- audio
- general Android compatibility
- zero-configuration consumer installation

## 2.5 Pen Display experimental contract

`PEN_DISPLAY` begins as a bounded M6 experiment, not as part of P2 acceptance. Its purpose is to determine whether a focused drawing surface can improve M-Pencil usefulness and authoritative-pixel latency.

Candidate source strategies:

- one selected window
- all relevant windows belonging to one selected application
- a dedicated MateBridge virtual display containing the target application

The experiment must test:

- floating tool panels and auxiliary windows
- popovers, menus, sheets, and modal dialogs
- source move/resize/minimize/close
- coordinate mapping after geometry changes
- app switching and focus ownership
- fallback to `DESKTOP_FULL`
- latency/resource benefit relative to full desktop capture

A selected-window demo is not enough to claim a production pen display. The supported application/source matrix and missing-window behavior must be explicit. MateBridge must not claim Cintiq-equivalent behavior unless the tested macOS application matrix actually supports it.

## 2.6 Headless support contract

“Headless” must never be used as an undefined marketing term. Each release declares which states are supported:

- initial setup with HDMI/TV available
- normal logged-in session with no physical monitor
- screen locked
- display asleep while system remains awake
- system sleep and wake
- logout/login
- reboot after automatic login, if used
- reboot with normal password login
- FileVault pre-boot login
- macOS update and first restart

A release may support only a subset. Unsupported states must have a documented fallback rather than an implied promise.

---

# 3. Assumption and Risk Register

Every high-impact assumption gets an owner, an experiment, a pass condition, and a fallback before implementation expands around it.

| ID | Assumption | Earliest validation | Pass evidence | Fallback if false |
|---|---|---|---|---|
| A01 | ScreenCaptureKit is stable enough on the exact Mac/macOS combination. | M0 | Capturable frames across target display states, with timestamps and no unexplained long-run stop. | Lower profile, alternate capture strategy, or narrower supported state. |
| A02 | A supported practical display exists when no permanent monitor is attached. | M0 | Stable display enumeration/capture after the declared startup boundary. | Explicit HDMI/TV or display-emulator fallback; defer full headless claim. |
| A03 | The exact MatePad exposes useful M-Pencil data through Android events. | M0 | Recorded tool type, coordinates, timing, pressure/tilt/button capabilities and sample distribution. | Reduce stylus scope to proven fields. |
| A04 | macOS can inject the required stylus semantics into selected applications. | M0 | Target applications receive and respond to injected events as declared. | Pointer-like stylus, application-specific support, or no pressure/tilt promise. |
| A05 | ADB-based USB transport is adequate for laboratory development. | M0 | Bidirectional traffic, measured throughput/RTT/jitter, repeated reconnect. | Use LAN for early development while USB feasibility continues. |
| A06 | A non-ADB production USB path is feasible if seamless USB becomes a product requirement. | M0/M4 decision | Supported connection model, signing/distribution implications, reconnect behavior. | Keep developer-mode USB for personal use or make LAN the product transport. |
| A07 | VideoToolbox plus Android hardware decoding can create a strong low-latency baseline. | M2/M3 | Hardware path confirmed; bounded queue trace; stable frame pacing. | Change codec/profile, reduce resolution/FPS, or simplify conversion path. |
| A08 | Cross-device latency can be measured with useful accuracy. | M0/M1 | Monotonic timestamps, clock-offset/drift estimate, trace continuity, one physical validation. | Report stage-local latency and external glass-to-glass tests separately. |
| A09 | Tile/region transfer materially beats video for target workloads. | M7 | Predeclared bandwidth/clarity/latency gate passes on replayed coding workloads. | Keep video-first and optimize frame rate, bitrate, ROI, and idle behavior. |
| A10 | Local ink prediction improves perceived stylus quality without objectionable correction. | M6 | Objective trace improvement plus blinded/structured subjective test. | Keep local cursor only; remove prediction complexity. |
| A11 | Permission grants and app identity remain reliable across normal updates. | M0/M4 | Signed build/update tests preserve or recover permissions predictably. | Explicit reauthorization workflow and narrower distribution model. |
| A12 | Automatic reconnect survives real lifecycle events. | M2-M5 | Failure matrix passes without stale input or corrupted display state. | Declare manual reconnect for unsupported transitions and keep diagnostics. |
| A13 | Remote access can be secured without turning MateBridge into a cloud platform. | M10 | Threat model, authenticated connection, revocation, parser hardening, recovery. | Ship local/LAN only or require an external private-network tunnel. |
| A14 | The exact Huawei keyboard/trackpad exposes sufficient event fidelity for daily use. | M0 | Raw key/pointer/scroll traces, Turkish layout and modifier matrix, drag/repeat/recovery tests, documented Android-consumed gestures. | Ship a reduced basic-input contract, remapping, or require an external input device for unsupported workflows. |
| A15 | A focused `PEN_DISPLAY` source is reliable and materially useful. | M6 | Source lifecycle matrix passes; coordinate mapping is stable; auxiliary-window limitations are explicit; latency/usability improves for selected workflows. | Keep `DESKTOP_FULL` only or restrict `PEN_DISPLAY` to a narrow application matrix. |
| A16 | Interaction-aware display scheduling reduces stylus-to-authoritative-pixel latency without starving or corrupting the rest of the display. | M6/M7 | Frozen p50/p95 improvement target passes with no unacceptable resource, quality, or starvation regression. | Remove the scheduler hint path; retain newest-frame video, local cursor, and other proven optimizations. |

### Risk register rules

- No red assumption may be hidden by adding more code.
- A yellow assumption requires a documented fallback and a release limitation.
- An assumption is not marked green from a single successful manual run.
- Results include exact build, device, OS, settings, raw logs, and reproduction steps.

---

# 4. Architecture Contract Before Architecture Freeze

Plan V2.1 does not freeze concrete codec, protocol library, or rendering technology in M0. It freezes only the boundaries that prevent later rewrites.

## 4.1 Logical planes

### Control plane

Responsibilities:

- discovery handoff
- pairing and trust
- capability negotiation
- session creation and generation number
- display profile selection
- experience-profile selection
- display-policy changes
- quality-policy changes
- active input capability/status changes
- permission/status reporting
- error and recovery commands
- heartbeat and shutdown

Control messages are reliable, ordered, bounded, and versioned.

### Display plane

Carries one or more of:

- full video frames
- region frames
- tiles
- cache invalidation
- full-state resynchronization

Display data is explicitly disposable or recoverable. Old video frames are dropped rather than queued indefinitely. Tile state has an epoch/generation and a defined full-resync path.

### Input plane

The input plane contains three semantic lanes. A transport may map them to separate streams, priorities, or latest-value paths, but their behavior is defined independently of the transport implementation.

#### `INPUT_RELIABLE_STATE`

Carries ordered state transitions that must not disappear:

- keyboard down/up and modifier state
- pointer/trackpad button down/up
- stylus down/up, proximity enter/leave, tool change, and cancellation
- touch begin/end/cancel where loss would leave stale state
- explicit release-all-state during focus loss, reconnect, or shutdown

#### `INPUT_REALTIME_POINTER`

Carries latency-sensitive, supersedable samples:

- relative or absolute pointer motion
- trackpad movement
- vertical/horizontal scroll and phase/momentum fields where exposed
- touch movement/gesture samples within the declared mapping contract

#### `INPUT_REALTIME_STYLUS`

Carries high-frequency M-Pencil samples:

- tool/sample ID and phase
- x/y
- pressure
- tilt and orientation/azimuth where exposed
- distance/hover where exposed
- button/eraser fields where exposed
- Android event timestamp
- historical samples and coalescing metadata

Reliable state transitions are never silently discarded. Real-time pointer or stylus move samples may be coalesced only under documented newest-useful-sample rules. A stylus move backlog must not delay a keyboard release, and display traffic must not starve any input lane.

### Cursor/overlay plane

Carries latest cursor position, shape/state, hover indicator, optional click feedback, and later optional predicted ink. It must not force full display invalidation.

### Metrics/trace plane

Carries structured counters and trace spans. It must be rate-limited and must not block display/input.

## 4.2 Session state machine

The host and client must share an explicit state model:

```text
UNINITIALIZED
    ↓
PERMISSION_REQUIRED ──────┐
    ↓                     │
IDLE                      │
    ↓                     │
DISCOVERING / ATTACHED    │
    ↓                     │
PAIRING                   │
    ↓                     │
NEGOTIATING               │
    ↓                     │
STREAMING ────────────────┤
    ↓                     │
DEGRADED                  │
    ↓                     │
RECONNECTING ─────────────┘
    ↓
SUSPENDED / STOPPED
```

Each state defines:

- allowed incoming messages
- timeout
- user-visible status
- log event
- cleanup action
- whether input is accepted
- whether display data is accepted
- recovery transition

A new session generation invalidates packets and cached state from an older session.

## 4.3 Capability negotiation

The first protocol handshake advertises, rather than assumes:

- protocol version range
- host/client build IDs
- supported experience profiles
- display resolution and refresh profiles
- pixel formats
- video codecs and profiles
- display policies and tile/region support
- quality-policy controls
- maximum message and buffer sizes
- physical keyboard/trackpad/touch capabilities
- input-lane and gesture fields
- stylus fields and sample metadata
- local overlay support
- interaction-hint support
- transport features
- authentication mode
- time-sync support

Unknown optional capabilities are ignored safely. Required incompatibility fails with a clear error instead of undefined behavior.

## 4.4 Queue and backpressure rules

Every queue has:

- a named owner
- a configured maximum
- current/high-water metrics
- an overflow rule
- a shutdown/cancellation rule

Default behavior principles:

- Capture: do not accumulate stale frames.
- Encode: latest useful frame wins.
- Transport: control/input priorities cannot be starved by display data.
- Decode: do not render an old backlog after network recovery.
- Render: presentation feedback must close the pacing loop.
- Tile cache: corruption or epoch mismatch triggers full resync.

Default scheduling priority, subject to bounded anti-starvation rules:

1. control, cancellation, and reliable input state transitions
2. newest useful real-time stylus samples
3. newest useful pointer/trackpad/touch samples
4. interaction-priority authoritative display updates when the feature is enabled
5. normal display data
6. metrics and non-critical diagnostics

Priority does not permit permanent starvation. The display still receives periodic authoritative progress/full resync, and metrics remain rate-limited rather than silently unbounded.

No “temporary unbounded queue” is allowed in a milestone build.

## 4.5 Time and trace model

Use monotonic clocks on both devices. Do not compare wall-clock timestamps directly.

Required trace fields:

- session ID and generation
- frame ID or input event ID
- host monotonic timestamp
- client monotonic timestamp
- current clock-offset estimate
- stage timestamps
- queue wait duration
- transport sequence
- experience profile, transport, display policy, quality policy, and input lane
- interaction-hint ID/region where applicable

Clock offset and drift are estimated with repeated bidirectional probes. Stage-local timing remains valid even if cross-device mapping is temporarily uncertain.

## 4.6 Display geometry and coordinate model

The protocol distinguishes:

- macOS logical points
- macOS backing pixels
- captured buffer pixels
- encoded frame pixels
- Android surface pixels
- physical tablet orientation

One transform object owns mapping in both directions. Input code does not contain ad hoc scaling formulas. The transform is scoped to the active experience profile and source identity so a `PEN_DISPLAY` window/source change cannot reuse stale `DESKTOP_FULL` geometry.

MVP display constraints:

- landscape only
- SDR only
- rotation disabled during a session
- one tested scaling path
- one canonical test card for text and geometry

## 4.7 Color and pixel-format policy

Start with one SDR, 8-bit pipeline. Select formats based on measured conversion cost and hardware compatibility. Avoid promising wide color, HDR, or perfect color management before the base path is stable.

The pipeline records:

- capture format
- encoder input format
- decoder output format
- renderer format
- conversion steps
- color range/matrix assumptions

Unexplained conversions are performance findings.

## 4.8 Transport adapter boundary

The session core sees a transport interface with:

- connect/accept
- reliable ordered stream
- optional datagram/latest-value path
- cancellation
- connection metrics
- path change notification
- maximum payload information

Initial adapters may include:

- loopback/in-process test transport
- ADB-forwarded TCP for laboratory USB
- LAN transport later
- remote transport later

Transport-specific code must not own display policy or input semantics.

## 4.9 Security baseline

Development-only ADB builds may use a clearly marked insecure laboratory mode. Any build exposed to LAN or Internet must have:

- explicit pairing
- mutual device authentication
- session encryption
- replay protection or equivalent session freshness
- revocable trust
- bounded parser inputs
- no unauthenticated public control listener
- redacted logs

The remote milestone adds a separate threat model rather than assuming local pairing is sufficient.

## 4.10 Experience-profile behavior

### `DESKTOP_FULL`

- Represents the complete selected Mac display/workspace.
- Is the mandatory P2 daily-driver profile.
- Uses the tested keyboard/trackpad/touch/stylus contract.
- Remains the safe fallback when an experimental focused source becomes invalid.

### `PEN_DISPLAY`

- Represents one selected application/window group or dedicated drawing display.
- Is selected explicitly; it is not inferred from content motion.
- Carries a source identity and geometry generation in control/display/input messages.
- Suspends or falls back deterministically if the source disappears, changes identity, or cannot include required auxiliary windows.
- May request a stylus-first quality/latency budget, but it does not bypass protocol safety, state cleanup, or authoritative display consistency.

## 4.11 Interaction-Aware Display Scheduling

The user-facing idea sometimes described as “pen-aware streaming” is represented architecturally as an optional **interaction hint**, not as a second source of truth.

A hint may contain:

```text
interactionHintId
sourceInputEventId
experienceProfile
centerX / centerY
radius or region
createdAt
expiresAt
priorityClass = STYLUS_ACTIVE
```

The hint may influence:

- capture wake-up or pacing
- newest-frame selection
- region/tile enqueue order
- encoder ROI where supported and measured
- transport scheduling of the first authoritative changed pixels

It must not:

- invent authoritative pixels
- reorder reliable input state
- starve the rest of the display indefinitely
- conceal a missing app render
- become a production dependency before M6/M7 evidence passes

Local predicted ink is a separate optional overlay. Interaction-aware scheduling accelerates return of **authoritative Mac-rendered pixels**; it does not replace them.

---

# 5. Repository and Project Operating System

## 5.1 Recommended repository structure

```text
matebridge/
├── apps/
│   ├── host-macos/
│   └── client-android/
├── protocol/
│   ├── schema/
│   ├── fixtures/
│   ├── compatibility/
│   └── PROTOCOL.md
├── experiments/
│   ├── macos-capture-probe/
│   ├── macos-input-probe/
│   ├── android-stylus-probe/
│   ├── android-keyboard-trackpad-probe/
│   ├── usb-transport-probe/
│   ├── virtual-display-probe/
│   ├── pen-display-probe/
│   ├── interaction-aware-scheduling/
│   └── tile-vs-video/
├── benchmarks/
│   ├── workloads/
│   ├── network-profiles/
│   ├── test-card/
│   ├── runner/
│   └── reports/
├── tools/
│   ├── trace-viewer/
│   ├── diagnostics-packager/
│   └── protocol-inspector/
├── docs/
│   ├── PRODUCT-CONTRACT.md
│   ├── ASSUMPTIONS.md
│   ├── STATE-MACHINE.md
│   ├── INPUT-SUPPORT-MATRIX.md
│   ├── TEST-MATRIX.md
│   ├── SECURITY.md
│   ├── KNOWN-LIMITATIONS.md
│   ├── RELEASE-CHECKLIST.md
│   └── adr/
├── .ai/
│   ├── WORKFLOW.md
│   ├── QUEUE.md
│   └── task-template.md
└── README.md
```

This remains one host, one client, one protocol, and a set of experiments. It is not a microservice architecture.

## 5.2 Mandatory source-of-truth documents

### `PRODUCT-CONTRACT.md`

Defines current supported hardware, OS versions, states, non-goals, product level, experience profiles, transport choices, display policies, and quality policies.

### `ASSUMPTIONS.md`

Tracks A01-A16, evidence, owner, status, fallback, and last validation build.

### `STATE-MACHINE.md`

Defines host/client states, transitions, timeouts, and cleanup.

### `INPUT-SUPPORT-MATRIX.md`

Defines the exact Huawei keyboard, trackpad, touch, and M-Pencil fields that are exposed, mapped, unsupported, application-specific, or experimental for each build.

### `PROTOCOL.md`

Defines framing, message classes, ordering, drop semantics, limits, capability negotiation, versioning, and resync.

### `TEST-MATRIX.md`

Defines required hardware tests, failure injections, benchmark workloads, and release gates.

### `KNOWN-LIMITATIONS.md`

Records every unsupported state that could surprise the user.

### ADRs

An Architecture Decision Record is required for decisions that would be expensive to reverse, including:

- capture API
- video codec baseline
- protocol framing/schema
- USB production strategy
- virtual-display strategy
- macOS input-injection strategy
- experience-profile and Pen Display source strategy
- input-lane ordering/coalescing semantics
- cryptographic/pairing design
- interaction-aware scheduling promotion
- adaptive display-policy algorithm

## 5.3 Version identity

Every host and client build visibly exposes:

- semantic product version
- git commit
- build timestamp
- protocol version
- build flavor: lab/dev/release
- target OS/SDK

Every benchmark and diagnostic bundle records both build identities.

## 5.4 CI baseline

Before first optimization, automated checks should cover:

- macOS build and unit tests
- Android build and unit tests
- formatting/static analysis
- protocol encode/decode fixtures, including input lanes and profile/policy negotiation
- deterministic keyboard/trackpad mapping fixtures where practical
- malformed-message tests
- state-machine transition and release-all-input tests
- deterministic benchmark-runner smoke test
- artifact version stamping

Hardware-in-loop tests remain separate but produce a standardized evidence bundle.

---

# 6. Measurement and Benchmark System

## 6.1 Measurement layers

### Software pipeline latency

```text
capture request/availability
→ capture callback
→ conversion
→ encoder submit/complete
→ transport enqueue/send
→ client receive
→ decoder submit/complete
→ compositor submit
→ presentation feedback
```

### Input round trip

```text
Android event
→ input-lane serialization
→ host receive
→ macOS injection
→ target application update
→ captured authoritative pixels
→ client presentation
```

### Stylus authoritative-pixel trace

```text
S0 Android M-Pencil sample
→ S1 Host receives the sample
→ S2 macOS injects the sample
→ S3 Target application produces changed authoritative pixels
→ S4 First relevant authoritative pixels are captured
→ S5 Relevant frame/region is enqueued and sent
→ S6 Client presents the authoritative pixels
```

When interaction-aware scheduling is enabled, the trace also records hint creation, expiration, selected region/ROI, queue priority, and whether non-priority display progress was delayed. Local predicted ink is traced separately from authoritative pixels.

### Physical glass-to-glass validation

At selected milestones, validate software traces with an external physical method. Software timestamps alone must not be described as true glass-to-glass latency without this check.

## 6.2 Required metrics

### Display

- delivered and presented FPS
- frame interval distribution
- dropped/replaced frames by stage
- capture-to-presentation p50/p95/p99
- queue wait p50/p95/p99
- visual corruption count
- resync count
- static text fidelity result

### Input

- event sample interval by input lane
- packet/coalescing count by input lane
- event-to-host-injection latency
- event-to-first-authoritative-changed-pixel latency
- event-to-relevant-region-presentation latency
- interaction-hint age, hit rate, and expiration count where enabled
- non-priority display starvation/progress metrics where enabled
- stuck key/button/stylus prevention events
- Huawei keyboard key/modifier/layout/repeat support result
- Huawei trackpad motion/click/drag/vertical-horizontal-scroll support result
- Android-consumed or unavailable gesture inventory
- pressure/tilt/hover fidelity where supported
- predicted-to-authoritative error where local ink is tested

### Resources

- host CPU/GPU/RAM
- client CPU/GPU/RAM
- encoder/decoder hardware use
- battery drain
- thermal state
- energy impact where available

### Transport

- throughput
- RTT
- jitter
- loss/retransmit
- queue delay
- reconnect duration
- bytes per workload and per hour

## 6.3 Reproducible workload manifest

Each benchmark defines:

- exact app and version
- display profile
- theme/font/scale where relevant
- action sequence
- warm-up period
- run duration
- network profile
- number of repetitions
- metrics collected
- success threshold frozen before the run

Required workloads:

- static code editor
- typing
- terminal output
- code and web scrolling
- window movement/resize
- UI animation
- 1080p and later 4K video
- pointer and drag interaction using the exact Huawei trackpad
- Huawei keyboard coding/shortcut/Turkish-layout session
- vertical and horizontal trackpad scrolling
- handwriting, circles, pressure ramp, tilt sweep
- `PEN_DISPLAY` source lifecycle with panels, popovers, dialogs, resize, minimize, and close
- interaction-aware stylus workload with foreground and background display changes
- cable disconnect/reconnect
- sleep/wake
- lock/unlock

## 6.4 Report discipline

A performance claim is accepted only when the report includes:

- baseline build and candidate build
- raw trace references
- environment manifest
- explicit experience profile, transport, display policy, and quality policy
- repeated results
- median and tail behavior
- resource cost
- visual-quality comparison
- known anomalies

A single favorable screenshot is not benchmark evidence.

---

# 7. Canonical Milestone Graph

```text
M0  PLATFORM VALIDATION + PROJECT SPINE
 │
 ├── M0-H  HEADLESS FEASIBILITY
 ├── M0-S  STYLUS SOURCE + macOS SINK
 ├── M0-K  HUAWEI KEYBOARD + TRACKPAD FIDELITY
 ├── M0-U  USB FEASIBILITY
 └── M1    FIRST PIXELS, FULLY INSTRUMENTED
            │
            └── combined M0 evidence gate
                         ↓
                 M2 INTERACTIVE USB / DESKTOP_FULL
                         ↓
                 M3 VIDEO CORE EXCELLENCE
                         ↓
                 M4 LOCAL DAILY-DRIVER
                    ┌────┴─────────────────────┐
                    ↓                          ↓
             M5 HEADLESS       M6 STYLUS QUALITY + PEN DISPLAY SPIKE
                    └──────────────┬───────────┘
                                   ↓
                         M7 ADAPTIVE THESIS
                                   ↓ gate pass only
                         M8 ADAPTIVE ENGINE
                                   ↓
                               M9 LAN
                                   ↓
                              M10 REMOTE
                                   ↓
                        M11 PRODUCTIZATION
```

M0 sub-spikes may run in parallel because they touch isolated experiment projects. Architecture decisions wait for the combined evidence pack. `PEN_DISPLAY`, interaction-aware scheduling, and local ink do not bypass M4 daily-driver readiness.

---

# 8. Detailed Milestones

## M0 — Platform Validation and Project Spine

### Objective

Destroy the largest uncertainties before building a large shared architecture.

### Ordered tasks

1. Record exact Mac model, chip, RAM, macOS build, Xcode/SDK, display states, FileVault status, and power settings.
2. Record exact MatePad model, OS build, Android API behavior, USB mode, refresh profiles, M-Pencil generation, and Huawei keyboard/trackpad model/firmware identity where visible.
3. Decide the initial distribution mode: local developer build, signed personal build, or distributable product build.
4. Create host and client skeleton applications with visible build identity.
5. Establish CI, unit-test scaffolding, structured logging, and diagnostics packaging.
6. Build the benchmark manifest format and trace event schema.
7. Benchmark the direct local display reference and Duet USB/Wi-Fi where available.
8. Build the macOS capture probe.
9. Build the Android stylus probe.
10. Build the Huawei keyboard/trackpad probe.
11. Build the macOS input-injection probe.
12. Build the USB transport probe.
13. Run the headless/virtual-display state matrix.
14. Run initial clock-offset/drift experiments.
15. Update the assumption register and write ADR candidates.

### M0-H — Headless feasibility spike

Test at minimum:

- physical display connected
- physical display disconnected after login
- cold boot with no display
- screen locked
- display sleep
- system sleep/wake
- logout/login
- FileVault or pre-login state if relevant
- resolution change
- host app crash/restart

Record whether a capturable display exists, whether permissions apply, and what manual action is required.

### M0-S — Stylus source and sink spike

Android source probe records:

- tool type
- x/y
- pressure distribution
- tilt/orientation
- hover/distance
- buttons/eraser
- historical samples
- event timestamps
- sampling distribution
- palm behavior

macOS sink probe records, for a selected application matrix:

- pointer location
- down/up
- pressure response
- tilt response
- proximity/hover response
- button mapping
- application-specific differences
- required permissions

The result is a **support matrix**, not a generic claim that “stylus works.”

### M0-K — Huawei keyboard and trackpad fidelity spike

Keyboard probe records:

- physical key code and scan information exposed to Android
- text/Unicode output
- key down/up and repeat
- Shift, Control, Alt/Option, Command mapping candidates
- Turkish Q layout behavior
- common shortcuts and multi-key combinations
- function/media keys where exposed
- focus loss/background behavior while a key is held

Trackpad probe records:

- relative versus absolute pointer semantics
- pointer sample timing
- left/right click where exposed
- press-hold-drag and cancellation
- vertical and horizontal two-finger scrolling
- phase/momentum data where exposed
- pinch and multi-finger gesture delivery where exposed
- gestures consumed by Android before the app receives them
- keyboard-cover attach/detach and client background/foreground behavior

The result defines two contracts:

1. **P2 guaranteed basic input:** movement, click, drag, vertical/horizontal scroll, keyboard down/up, modifiers, repeat, and tested Turkish layout behavior.
2. **Experimental advanced input:** pinch, workspace switching, Mission Control-like gestures, momentum fidelity, and any system-consumed multi-finger gestures.

### M0-U — USB feasibility spike

Measure:

- setup steps
- connection role and detection
- bidirectional throughput
- RTT and jitter
- sustained transfer
- cable unplug/replug
- app restart
- Mac restart
- MatePad app restart
- whether developer options/ADB are required
- feasibility of a later non-ADB path

### Deliverables

- `docs/PRODUCT-CONTRACT.md`
- `docs/ASSUMPTIONS.md`
- `docs/TEST-MATRIX.md`
- `docs/KNOWN-LIMITATIONS.md`
- baseline report
- stylus capabilities report
- Huawei keyboard/trackpad capability and mapping report
- `docs/INPUT-SUPPORT-MATRIX.md`
- macOS stylus-injection report
- headless feasibility report
- USB feasibility report
- initial trace viewer or generated trace summary

### Exit criteria

- Every critical assumption has green/yellow/red evidence.
- There is a viable fallback for every yellow/red result that remains in scope.
- First product level, supported experience profile, and startup boundary are explicit.
- The P2 minimum Huawei keyboard/trackpad contract is either proven or narrowed with a documented fallback.
- The project can build host and client reproducibly.
- No codec/protocol/virtual-display choice is frozen without evidence.

### Stop condition

Do not proceed to shared product architecture if there is no viable display path, no viable input-control path, and no acceptable fallback for the actual intended use.

---

## M1 — First Pixels, Fully Instrumented

### Objective

Show live Mac desktop pixels on the MatePad through the laboratory USB path with traceability from capture to presentation.

### Scope

- one display source
- one fixed landscape resolution profile
- SDR only
- one simple full-frame path
- ADB-forwarded or equivalent lab USB
- frame IDs and stage timestamps
- FPS, bandwidth, queue depth, and error overlay
- manual start is acceptable

### Required engineering

1. Define protocol v0 framing and hard size limits.
2. Implement host capture adapter.
3. Implement one conversion/serialization path.
4. Implement transport send/receive.
5. Implement Android frame receiver and presentation.
6. Implement session ID/generation.
7. Implement heartbeat and orderly shutdown.
8. Implement bounded queues from the first frame.
9. Implement a full-state reset after reconnect.
10. Capture a diagnostics bundle.

### Non-goals

- input
- adaptive display policies
- virtual display productization
- automatic reconnect polish
- high-motion quality optimization
- perfect scaling/UI

### Exit criteria

- A sustained run completes without unbounded memory growth.
- The displayed image is geometrically correct.
- Frame IDs are traceable end-to-end.
- Queue overflow behavior is visible and deterministic.
- Disconnect produces a defined state rather than a frozen fake connection.
- The result can be reproduced from a clean checkout and documented setup.

---

## M2 — Interactive USB Vertical Slice

### Objective

Use the MatePad in `DESKTOP_FULL` as one coherent Mac session through the exact Huawei keyboard/trackpad, touch surface, and basic M-Pencil path.

### Ordered implementation

1. Finalize the experience-profile-aware coordinate transform object.
2. Implement the P2 physical-input contract selected from M0-K evidence.
3. Add Huawei trackpad pointer motion and the measured relative/absolute mapping.
4. Add button down/up, click, press-hold-drag, cancellation, and right-click behavior where exposed.
5. Add vertical/horizontal scrolling and only the phase/momentum fields actually exposed.
6. Add keyboard down/up, modifiers, repeat, shortcuts, and text/layout decisions.
7. Test the actual Huawei keyboard with Turkish layout behavior and stuck-key recovery.
8. Add touch mapping and cancellation.
9. Add `INPUT_RELIABLE_STATE`, `INPUT_REALTIME_POINTER`, and `INPUT_REALTIME_STYLUS` protocol semantics.
10. Add basic stylus x/y, down/up, and only the fields proven in M0-S.
11. Add input sequence numbers, lane metrics, and event tracing.
12. Add permission detection/onboarding for capture and event posting.
13. Implement the shared session state machine.
14. Add reconnect with a new session generation.
15. On reconnect, device detach, or focus loss, release all logically held keys/buttons/touch/stylus state.

### Important rule

High-frequency pointer or stylus movement may be coalesced. Reliable state transitions may not be discarded. Real-time stylus traffic may not delay keyboard/button release events.

### Exit criteria

- The exact Huawei trackpad supports the declared pointer, click, drag, and scroll contract in a scripted test.
- The exact Huawei keyboard supports the declared Turkish layout, modifiers, repeat, and shortcut contract.
- No stuck input remains after cable disconnect, keyboard-cover detach, app backgrounding, focus loss, or reconnect.
- Basic stylus reaches the host and target application as declared.
- Permission failure is visible and recoverable.
- A short real coding session is completed in `DESKTOP_FULL` using the MatePad screen and Huawei keyboard/trackpad, without an external keyboard or mouse.

---

## M3 — Video Core Excellence

### Objective

Create the strongest practical high-motion baseline before tile work begins.

### Ordered implementation

1. Query and record available hardware encoder/decoder capabilities.
2. Select the initial codec/profile through an ADR.
3. Minimize pixel-format conversions.
4. Implement hardware encode/decode.
5. Implement explicit low-latency configuration.
6. Implement presentation-aware frame pacing.
7. Enforce capture, encode, transport, decode, and render queue budgets.
8. Define late-frame drop and keyframe recovery behavior.
9. Add profile negotiation for tested resolution/FPS combinations.
10. Add local cursor composition so cursor motion does not require desktop pixels.
11. Add short and long soak tests.
12. Run static, scrolling, UI-motion, and video workloads.

### Exit criteria

- The hardware path is confirmed rather than inferred.
- Tail latency and queue depth are stable under sustained load.
- Scrolling and window motion are usable without runaway backlog.
- Decoder/encoder reset and reconnect recover cleanly.
- 60 Hz work is either demonstrated at the selected profile or the supported profile is explicitly lowered based on evidence.
- A benchmark report establishes the video baseline for all later comparisons.

### Gate

No tile or hybrid implementation begins before this baseline report is accepted.

---

## M4 — Local Daily-Driver Beta

### Objective

Turn the laboratory vertical slice into a system that survives normal daily use over USB.

### Ordered implementation

1. Pair and remember the exact host/client relationship.
2. Implement launch-at-login within the selected distribution model.
3. Implement auto-attach/auto-reconnect policy.
4. Handle cable disconnect/reconnect.
5. Handle client foreground/background and screen on/off.
6. Handle host lock/unlock, display changes, and sleep/wake within supported states.
7. Add crash detection and restart/recovery.
8. Add a small connection/status UI based on the state machine.
9. Add a one-action diagnostics export.
10. Add safe defaults and remove developer-only controls from the normal screen.
11. Add release build signing and update-identity tests.
12. Run failure injection and work-session soak tests.

### Daily-driver acceptance script

- Start from the declared normal state in `DESKTOP_FULL`.
- Connect without terminal commands, except where the product contract explicitly allows them.
- Use the MatePad screen and exact Huawei keyboard/trackpad; do not use an external keyboard or mouse.
- Complete a representative coding/productivity session.
- Perform repeated trackpad scroll, drag, Turkish text entry, shortcuts, app switching, touch/stylus use, and idle periods.
- Disconnect/reconnect USB.
- Lock/unlock the Mac.
- Background/foreground the MatePad client.
- Recover from one host-process restart and one client-process restart.
- Export diagnostics.

### Exit criteria

- The daily-driver script passes on the exact hardware with the declared Huawei keyboard/trackpad contract and no external keyboard or mouse.
- No critical failure requires clearing app data or rebuilding.
- Known limitations are documented.
- Resource use and thermal behavior remain bounded through the acceptance session.
- The TV/HDMI fallback is not required during the supported post-login session.

---

## M5 — Supported Headless Beta

### Objective

Make the MatePad the normal display after the exact supported startup boundary established in M0.

### Ordered implementation

1. Select the supported virtual-display or fallback strategy through an ADR.
2. Create and persist the desired display profile.
3. Detect missing/stale display state.
4. Recreate or rebind the display after crash/restart.
5. Integrate launch and reconnect ordering.
6. Handle display sleep, lock, user-session transitions, and resolution changes.
7. Define cold-boot and FileVault behavior honestly.
8. Add recovery instructions and fallback path.
9. Run repeated boot/session lifecycle tests.

### Exit criteria

- No permanent monitor is required during every state the release claims to support.
- Unsupported pre-login/update states are explicit.
- A failed headless start has a deterministic recovery path.
- Display identity and resolution do not drift unpredictably across normal restarts.

### Stop condition

Do not hide an unsupported pre-login state behind “headless” wording. If a supported public path is unavailable, ship a narrower post-login headless contract or require a documented fallback.

---

## M6 — Stylus Quality and Pen Display Spike

### Objective

Improve M-Pencil usefulness only after basic end-to-end stylus semantics are proven, while testing whether a focused `PEN_DISPLAY` experience and interaction-aware authoritative-pixel scheduling deserve production support.

### Ordered experiments

1. Establish the target-application stylus matrix and expected supported fields.
2. Finalize `INPUT_REALTIME_STYLUS` sample identity, sequencing, coalescing, and reliable state transitions.
3. Align Android event timestamps with the host trace.
4. Compare immediate send, small batching, historical-sample forwarding, and event coalescing.
5. Test coordinate smoothing without hiding real motion.
6. Measure pressure, tilt, hover/proximity, button, and application behavior.
7. Add local hover/cursor prediction if useful.
8. Build `PEN_DISPLAY` source spikes for selected window, relevant application-window group, and dedicated virtual-display strategies where feasible.
9. Test panels, popovers, dialogs, move/resize/minimize/close, focus changes, and source loss.
10. Compare full desktop versus focused-source latency, resource cost, text/ink quality, and geometry reliability.
11. Build interaction-aware scheduling experiments: newest-frame selection, capture wake/pacing, region priority, and encoder ROI only where supported.
12. Measure stylus-to-first-authoritative-pixel and stylus-to-relevant-region-presentation latency.
13. Build a minimal local ink overlay experiment separately from authoritative-pixel scheduling.
14. Measure predicted-to-authoritative reconciliation error.
15. Run structured subjective comparison against no prediction, `DESKTOP_FULL`, and Duet where possible.

### Pen Display promotion gate

`PEN_DISPLAY` enters a supported build only when:

- source selection and loss have deterministic state transitions,
- coordinate mapping remains correct after geometry changes,
- required auxiliary windows are included or limitations are explicit,
- focus and input ownership do not become ambiguous,
- it provides a measured or clearly demonstrated workflow benefit over `DESKTOP_FULL`,
- fallback to `DESKTOP_FULL` is safe and immediate,
- the supported application/source matrix is published.

### Interaction-aware scheduling promotion gate

Interaction-aware scheduling enters production only when a frozen benchmark demonstrates:

- a material improvement in p50/p95 stylus-to-authoritative-pixel latency,
- no unacceptable increase in CPU/GPU/battery use,
- no visible corruption or cache inconsistency,
- bounded background-region delay and no permanent starvation,
- clean disable/fallback behavior on unsupported display policies.

If it fails, remove the hint path rather than preserving dormant complexity.

### Local ink promotion gate

Local ink enters production only when:

- perceived latency improves consistently,
- correction does not produce distracting jumps or double strokes,
- cancellation and tool changes are correct,
- unsupported applications can disable it safely,
- its CPU/GPU/battery cost is acceptable.

### Exit criteria

- The supported stylus feature matrix is accurate per target application.
- Basic writing/drawing does not lose down/up, tool, or pressure state.
- `PEN_DISPLAY` is either promoted with an explicit support matrix or rejected/narrowed.
- Interaction-aware scheduling is either promoted with evidence or removed.
- Prediction is either promoted with evidence or explicitly rejected.
- “Perfect stylus,” “Cintiq replacement,” or universal application support is not claimed outside measured evidence.

---

## M7 — Adaptive Display-Policy Thesis

### Objective

Determine whether tile/region transport deserves production complexity.

### Required candidates

At minimum compare:

- strong continuous video baseline
- idle-aware low-frame-rate video
- newest-frame/interaction-aware video variant if M6 retained it
- dirty-region transfer with and without interaction priority
- at least two tile sizes or a measured tile-size search
- optional video ROI strategy if supported, practical, and traceable

### Benchmark rules

- Freeze success criteria before running the comparison.
- Use the same experience profile, display geometry, and visual target within each comparison.
- Replay identical coding, typing, terminal, scrolling, and UI workloads.
- Record bandwidth, latency, host/client resources, queue behavior, and text fidelity.
- Include transition cost, not only steady-state static cost.
- Include worst cases such as scrolling and window movement.

### Decision options

#### Option A — Video-first only

Adopt if tiles do not create a material net benefit.

#### Option B — Static/region plus video

Adopt if static/coding gains are strong and transitions are manageable.

#### Option C — Manual workload profiles

Adopt if automatic classification is unstable but user-selected workload/display-policy profiles are useful.

### Exit criteria

- One option is selected through an ADR.
- The rejected options remain reproducible experiments, not half-integrated production code.
- The result includes a clear explanation of where the adaptive thesis holds and where it does not.

---

## M8 — Adaptive Display Engine

### Entry condition

M7 selected an adaptive display-policy production path.

### Objective

Make display-policy adaptation invisible and self-healing while preserving the selected experience profile.

### Ordered implementation

1. Implement one simple global display policy before per-region complexity.
2. Keep experience profile, transport, display policy, and quality policy as separate state.
3. Use measured features only.
4. Add hysteresis and minimum dwell time.
5. Define transition protocol and cache epoch behavior.
6. Force a safe full-state resync after uncertainty.
7. Add display-policy reason codes to diagnostics.
8. Preserve bounded anti-starvation when interaction priority is enabled.
9. Test rapid scroll/idle/video transitions in each supported experience profile.
10. Test packet loss/reconnect during each display policy.
11. Add user override only when automatic policy has a demonstrated failure case.

### Exit criteria

- No visible corruption or long freeze occurs during normal display-policy changes.
- Display-policy oscillation is absent under benchmark workloads.
- The measured benefit survives the integrated system, not only the experiment.
- Video remains a reliable fallback.

---

## M9 — LAN Beta

### Objective

Remove the cable on the same trusted network without weakening lifecycle or security.

### Ordered implementation

1. Select LAN transport through measured experiments.
2. Implement discovery without making discovery equal trust.
3. Implement authenticated pairing.
4. Encrypt the session.
5. Preserve control/input priority under congestion.
6. Add RTT/jitter/throughput estimator.
7. Add quality-policy adaptation and bounded recovery without silently changing the experience profile.
8. Handle Wi-Fi roaming, temporary loss, and IP change.
9. Run network impairment profiles.
10. Extend failure and security tests.

### Exit criteria

- Normal coding/productivity is comfortable on the target LAN.
- A stranger on the LAN cannot control or view the Mac without pairing.
- Temporary path loss recovers without stuck input or stale display state.
- USB and LAN share session semantics rather than duplicated product logic.

---

## M10 — Remote Internet Beta

### Objective

Provide secure different-network access without making remote support assumptions invisible.

### Entry requirements

- Local and LAN lifecycle are stable.
- Protocol parser limits and authentication are reviewed.
- A written threat model exists.
- Device revocation and recovery exist.

### Ordered implementation

1. Define the remote topology and trust model.
2. Decide direct connection, private-network tunnel, NAT traversal, and relay policy.
3. Implement secure device identity and key rotation strategy.
4. Add explicit remote approval/revocation behavior.
5. Add connection quality estimation.
6. Add remote reconnect and path migration behavior.
7. Add adaptive quality policies while preserving explicit experience-profile selection.
8. Add session bandwidth accounting.
9. Test hostile inputs and malformed protocol data.
10. Run LTE-like, high-latency, loss, and constrained-bandwidth profiles.
11. Perform independent security review.

### Exit criteria

- No unauthenticated public display/control service exists.
- Lost devices can be revoked.
- Remote failure does not leave held keys/buttons or a false connected state.
- Bandwidth counters are measured, not estimated from marketing constants.
- The declared remote scenarios pass the threat and failure matrices.

---

## M11 — Productization

### Objective

Package only the proven product levels.

### Scope

- installer/package strategy
- signing/notarization as applicable
- onboarding and permission recovery
- update mechanism
- stable device management
- logs and diagnostics UI
- crash reporting only with explicit consent
- hardware/input/application compatibility matrix
- UI that presents experience profile, transport, and quality separately while keeping low-level display policy in diagnostics unless needed
- release notes and known limitations
- rollback/recovery mode
- support bundle generation

### Exit criteria

- A clean installation follows the documented path.
- Update does not silently destroy trust or permissions without recovery.
- Release build can be identified and diagnosed.
- Product claims match the tested support matrix.

---

# 9. Exact Priority Queue for Starting Development

The first implementation queue should be processed in this order unless an item is explicitly parallelized:

1. Write `PRODUCT-CONTRACT.md` with P0/P1/P2 scope and the four product axes.
2. Create `ASSUMPTIONS.md` from A01-A16.
3. Inventory exact hardware, OS, security, Huawei keyboard/trackpad, M-Pencil, and cable details.
4. Decide initial signing/distribution mode.
5. Create monorepo skeleton and visible build identity.
6. Establish macOS and Android clean builds in CI.
7. Define structured log envelope and diagnostics bundle format.
8. Define trace-event schema, monotonic timestamp policy, and input-lane fields.
9. Create benchmark manifest schema and one static text/geometry test card.
10. Capture Duet/direct-display baseline.
11. Build macOS capture probe.
12. Run capture across monitor/headless/lock/sleep states.
13. Build Android M-Pencil diagnostic.
14. Build Huawei keyboard/trackpad diagnostic.
15. Record raw M-Pencil capability data.
16. Record raw keyboard/trackpad mapping, gesture-interception, and lifecycle data.
17. Build macOS event-injection diagnostic.
18. Test pointer, pressure, tilt, hover/proximity, and buttons in selected applications.
19. Build USB bidirectional transport probe.
20. Run repeated cable/restart/reconnect tests.
21. Implement cross-device clock-offset/drift probe.
22. Publish M0 evidence pack and resolve architecture decisions.
23. Define protocol v0 framing, limits, session generation, product axes, and input lanes.
24. Implement first captured frame over loopback.
25. Implement first captured frame over USB lab transport.
26. Implement Android presentation and frame trace.
27. Add bounded queues and memory/queue metrics.
28. Pass M1 first-pixels acceptance.
29. Implement experience-profile-aware coordinate transforms.
30. Implement the proven Huawei keyboard/trackpad P2 mapping contract.
31. Add pointer, button, drag, vertical/horizontal scroll, and cancellation.
32. Add keyboard down/up, Turkish layout, modifiers, repeat, and shortcut tests.
33. Add touch mapping.
34. Add reliable-state, real-time pointer, and real-time stylus lanes with basic M-Pencil fields.
35. Add permission onboarding.
36. Add state machine, release-all-input behavior, and reconnect cleanup.
37. Pass M2 `DESKTOP_FULL` acceptance without an external keyboard or mouse.
38. Implement hardware video baseline and frame pacing.
39. Run M3 benchmark suite and soak tests.
40. Implement local cursor/hover overlay.
41. Add pairing, launch, reconnect, diagnostics, and lifecycle recovery.
42. Pass P2 daily-driver acceptance using the MatePad screen and Huawei keyboard/trackpad.
43. Implement the headless strategy selected in M0.
44. Pass the supported headless state matrix.
45. Run stylus batching, historical-sample, pressure/tilt/hover, and application-fidelity experiments.
46. Run `PEN_DISPLAY` source-strategy and lifecycle spike.
47. Run interaction-aware authoritative-pixel scheduling experiments.
48. Run local ink prediction/reconciliation experiment.
49. Resolve the Pen Display, interaction-aware scheduling, and local ink gates independently.
50. Run tile/region/video thesis benchmark, including retained interaction-aware variants.
51. Implement the adaptive display engine only after a pass decision.
52. Add LAN only after local lifecycle and security gates are stable.
53. Add remote only after LAN and Internet security gates pass.

This queue prevents Pen Display enthusiasm, adaptive display-policy work, Internet work, or polished UI from consuming effort before the `DESKTOP_FULL` local product is real.

---

# 10. Development Work Cycle

Every non-trivial issue follows this cycle:

```text
Problem statement
→ Assumption or user failure being addressed
→ Smallest validating experiment
→ Required instrumentation
→ Frozen acceptance criteria
→ Implementation
→ Automated tests
→ Hardware test
→ Independent review
→ Evidence update
→ Merge or reject
```

## 10.1 Task packet template

Every implementation agent receives:

- task ID and milestone
- user-visible objective
- current evidence
- assumptions being tested
- active experience profile, transport, display policy, and quality policy
- affected physical input devices and support-matrix entries
- exact in-scope files/modules
- explicitly forbidden scope
- protocol/state-machine implications
- required logs/metrics
- automated tests
- hardware acceptance script
- performance budget or “no regression” rule
- rollback plan
- deliverables
- definition of done

No agent should be told only “optimize latency” or “implement stylus.”

## 10.2 Single-writer rule

At any moment:

- one owner edits the protocol contract,
- one owner edits the macOS capture path,
- one owner edits the Android renderer,
- one owner edits the input state machine and lane semantics,
- one owner edits active experience-profile/source lifecycle logic.

Other agents may inspect and review but do not produce competing implementations in the same production files. Competing ideas belong in isolated experiments.

## 10.3 Agent roles

### Lead / synthesis agent

- maintains product contract and milestone gate
- writes task packets
- approves ADRs
- integrates evidence
- prevents scope creep
- owns final merge decision

### Implementation agent

- works on one bounded task
- adds tests and instrumentation
- does not redesign neighboring subsystems without an approved ADR

### Platform specialist

- reviews Apple or Android API correctness
- checks permissions, lifecycle, threading, and hardware assumptions

### Performance reviewer

- audits measurement method, queueing, clock domains, and benchmark claims

### Security reviewer

- required for pairing, identity, network exposure, parser, update, or privileged-helper changes

### Independent code reviewer

- reviews the actual diff and test evidence
- challenges missing cleanup, error states, and hidden buffering

## 10.4 Pull request gate

A PR is mergeable only when:

- scope matches the task packet,
- build identity is preserved,
- tests pass,
- new states/errors are handled,
- queues remain bounded,
- metrics/logs exist for critical behavior,
- protocol changes include compatibility handling,
- hardware evidence is attached when required,
- affected keyboard/trackpad/stylus/application support-matrix entries are updated,
- known limitations are updated,
- rollback is possible.

A reviewer should reject a convincing implementation that lacks reproducible evidence.

---

# 11. Test and Failure Matrix

## 11.1 Host lifecycle

- app launch/quit/restart
- permission absent/granted/revoked
- physical monitor attach/detach
- display profile change
- lock/unlock
- screen sleep/wake
- system sleep/wake
- logout/login
- reboot
- update/re-sign test
- low memory/thermal pressure where practical

## 11.2 Client lifecycle

- app launch/quit/restart
- foreground/background
- screen off/on
- notification interruption
- USB permission/detection change
- Huawei keyboard-cover attach/detach
- battery saver
- orientation change attempt
- renderer/decoder reset
- low memory/thermal pressure

## 11.3 Transport

- clean USB
- cable removed during video
- cable removed during held mouse/stylus/key state
- rapid repeated reconnect
- partial packet/frame
- malformed length/header
- slow receiver
- send queue saturation
- LAN latency/jitter/loss later
- IP/path change later

## 11.4 Display

- static text
- small cursor movement
- typing caret changes
- terminal flood
- slow and fast scroll
- window drag/resize
- full-screen video
- display-policy transition
- resolution change
- cache corruption/resync
- `PEN_DISPLAY` source move/resize/minimize/close
- auxiliary panels, popovers, menus, sheets, and dialogs
- fallback from `PEN_DISPLAY` to `DESKTOP_FULL`
- interaction-priority region plus simultaneous background updates

## 11.5 Input

- exact Huawei trackpad pointer move and sample continuity
- single/double click and right-click where exposed
- press-hold-drag, cancel, and device detach during drag
- vertical/horizontal two-finger scroll
- phase/momentum fields where exposed
- Android-consumed multi-finger gesture inventory
- exact Huawei keyboard key down/up
- modifier combinations and common shortcuts
- key repeat
- Turkish Q layout behavior
- function/media keys where exposed
- focus loss or keyboard-cover detach while key held
- reliable-state versus real-time-lane starvation tests
- stylus down/move/up and tool change
- pressure ramp
- tilt sweep
- hover/proximity where supported
- palm/multitouch interaction
- stylus burst while keyboard/button release is pending

## 11.6 Soak levels

- smoke: short scripted validation after each relevant PR
- milestone soak: sustained representative session
- release-candidate soak: workday-scale mixed session using the MatePad screen and Huawei keyboard/trackpad plus lifecycle interruptions

Exact durations are recorded in `TEST-MATRIX.md` and may increase as the product matures. Results include tail latency and resource drift, not only success/failure.

---

# 12. Decision Gates

## Gate G0 — Viable local product

Proceed only if there is a usable display path, physical keyboard/trackpad input path, basic stylus/control path, and transport path or accepted fallback.

## Gate G1 — Video baseline accepted

Tile work is blocked until the hardware-video path is stable, measured, and queue-bounded.

## Gate G2 — Daily-driver ready

Headless productization and advanced optimization are blocked until `DESKTOP_FULL` USB lifecycle passes using the exact Huawei keyboard/trackpad without an external keyboard or mouse.

## Gate G3 — Headless claim

The release uses “headless” only for states that pass the declared matrix.

## Gate G4A — Pen Display

`PEN_DISPLAY` is rejected or narrowed if source lifecycle, auxiliary-window behavior, coordinate mapping, or workflow benefit does not pass the frozen matrix.

## Gate G4B — Interaction-aware scheduling

The hint/scheduling path is removed if it does not materially improve authoritative-pixel latency or if it creates starvation, corruption, or unacceptable resource cost.

## Gate G4C — Local ink prediction

Prediction is removed if it does not improve measured/structured subjective results or produces distracting reconciliation.

## Gate G5 — Adaptive display engine

Adaptive display-policy production code is rejected if it does not pass a predeclared net-benefit threshold.

## Gate G6 — LAN exposure

LAN is blocked until pairing, encryption, parser limits, and revocation design are ready.

## Gate G7 — Internet exposure

Internet is blocked until threat model, authentication, revocation, reconnect safety, and independent security review pass.

## Gate G8 — Product claim

Documentation and UI may claim only behavior tested on the support matrix.

---

# 13. Deferred Backlog with Entry Criteria

| Item | Entry criterion |
|---|---|
| 90/120 Hz | P2/P3 stable; 60 Hz tail latency and frame pacing excellent; hardware path measured. |
| Advanced MacBook-like trackpad gestures | Basic Huawei trackpad contract is stable; Android exposes required gesture data; macOS mapping is supportable and tested. |
| Generalized Pen Display application support | M6 passes for a narrow support matrix; source and auxiliary-window behavior can be generalized without hidden failures. |
| Automatic experience-profile switching | A concrete user problem proves manual profile selection inadequate; source/focus changes remain deterministic. |
| HDR/wide color | SDR pipeline stable; color-management requirements and cost measured. |
| AV1 | Remote bandwidth is a demonstrated bottleneck and hardware latency support is verified. |
| Multiple displays | Single-display lifecycle and protocol state are stable. |
| Multiple clients | Security/session ownership model is redesigned and reviewed. |
| Audio/microphone | Display/input daily-driver path is stable and separate latency/sync requirements are specified. |
| Clipboard/file transfer | Remote threat model and permission model are mature. |
| Monthly data budget UI | Remote bandwidth accounting is accurate over real sessions. |
| Custom USB stack | ADB/developer-mode path is a proven product blocker and a supported alternative is feasible. |
| Per-region mixed codecs | The global adaptive display policy is stable and measurements show remaining benefit. |
| General Android support | The exact MatePad product reaches stable release quality. |
| Windows/Linux host | macOS architecture boundaries are mature and product demand justifies expansion. |

---

# 14. What “Smooth Development” Means in Practice

The process is smooth when:

- the next task is determined by a milestone gate, not by whichever feature sounds interesting;
- architecture decisions are based on evidence packs and ADRs;
- experiments cannot silently become production dependencies;
- one agent owns each active subsystem;
- every failure produces a state, error code, log, and recovery path;
- performance changes include before/after traces;
- experience profile, transport, display policy, and quality policy are never conflated in tasks or reports;
- input support claims come from the exact Huawei keyboard/trackpad/M-Pencil matrix;
- protocol changes cannot break old builds silently;
- hardware-specific findings are recorded once and reused;
- the user tests a small acceptance script rather than improvising dozens of checks;
- main remains buildable and each milestone produces a known runnable build;
- unsupported scenarios are documented instead of disguised as unfinished polish.

---

# 15. Immediate Starting Package

The first repository work should consist of four bounded issue groups.

## Issue Group 01 — Project Contract and Evidence Spine

Deliver:

- `PRODUCT-CONTRACT.md` with the four product axes
- `ASSUMPTIONS.md` covering A01-A16
- build identity
- CI skeleton
- structured log envelope
- diagnostics bundle schema
- benchmark manifest schema

## Issue Group 02 — Mac Reality Probes

Deliver:

- capture probe
- headless/display-state report
- permission report
- input-injection probe
- target-application stylus support table

## Issue Group 03 — MatePad Input Reality Probes

Deliver:

- stylus diagnostic APK
- Huawei keyboard/trackpad diagnostic APK or integrated probe
- raw stylus, key, pointer, scroll, and lifecycle sample export
- M-Pencil capability report
- Huawei keyboard/trackpad capability and mapping report
- initial `INPUT-SUPPORT-MATRIX.md`
- client device/refresh/USB inventory

## Issue Group 04 — USB and Clock Probe

Deliver:

- bidirectional transport probe
- reconnect report
- throughput/RTT/jitter report
- monotonic time-sync experiment
- recommendation for M1 laboratory transport

Only after all four issue groups close should the lead agent write the M1/M2 implementation task packets and freeze the initial `DESKTOP_FULL` input contract.

---

# 16. Final Rules

1. The `DESKTOP_FULL` local product must work before its differentiator is optimized.
2. MateBridge is judged as a coherent workstation terminal, not by display FPS alone.
3. Experience profile, transport, display policy, and quality policy are separate axes.
4. The exact Huawei keyboard/trackpad is a P2 acceptance dependency, not a generic accessory assumption.
5. Headless feasibility is investigated early; headless reliability is implemented after the local session is stable.
6. Stylus capability is proven both on Android input and macOS application output.
7. `PEN_DISPLAY` begins as an experiment and always retains a deterministic `DESKTOP_FULL` fallback.
8. Video is the mandatory baseline; tiles must earn their complexity.
9. Interaction-aware scheduling must improve authoritative pixels, not merely look clever in traces.
10. Local predicted ink is separate from authoritative-pixel scheduling and has its own rejection gate.
11. Hidden buffering is treated as a defect.
12. State transitions are product behavior, not incidental error handling.
13. Critical input release/cancel events are never dropped.
14. Real-time stylus traffic may not starve reliable keyboard/button state.
15. Every reconnect starts a new session generation and invalidates stale display, source, interaction-hint, and input state.
16. Every performance result is tied to exact hardware, software, workload, build, and all four product axes.
17. Every experimental feature has a rejection path.
18. Security begins before LAN exposure, not after the remote transport is built.
19. Product claims follow the tested hardware, application, and lifecycle support matrices.
20. One bounded task, one implementation owner, one independent reviewer.
21. No large rewrite without a failed gate or measured bottleneck.
22. The next milestone is always the smallest one that can invalidate the largest remaining assumption.

---

# 17. Recommended First Release Sequence

```text
Release 0 — Diagnostic Pack
Capture/headless + stylus source/sink + Huawei keyboard/trackpad + USB/clock reports

Release 1 — First Pixels Lab
Instrumented display over developer USB

Release 2 — Interactive USB Alpha
`DESKTOP_FULL` display + Huawei keyboard/trackpad + touch + basic stylus

Release 3 — Local Daily-Driver Beta
Hardware video, lifecycle recovery, reconnect, diagnostics, and no-external-input acceptance

Release 4 — Supported Headless Beta
MatePad as normal display inside the declared startup boundary

Release 5 — Stylus Quality Beta + Pen Display Experimental Profile
Measured stylus support plus independently gated `PEN_DISPLAY`, interaction-aware scheduling, and optional prediction

Release 6 — Adaptive Local Beta
Only if the tile/region/video thesis passes

Release 7 — LAN Beta
Authenticated encrypted local wireless use

Release 8 — Remote Beta
Threat-modeled secure remote use and measured quality/data policies
```

This sequence gives the user a usable system as early as possible while keeping the technically ambitious parts optional and evidence-driven.
