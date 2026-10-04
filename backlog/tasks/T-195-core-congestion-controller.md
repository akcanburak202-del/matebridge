---
id: T-195
title: Write a pure Wi-Fi congestion controller (in-flight budget, fast-down/slow-up)
status: done
phase: 6
owner: mac-host-dev
depends_on: [T-127]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Video/CongestionController.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/CongestionControllerTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/CongestionReplayTrace.swift
  - backlog/tasks/T-195-core-congestion-controller.md
---

## Amaç

**Gated: start only after T-127's NOTES entry records decision 0023 branch "go adaptive" (rule recorded by T-127), and the numbers-only topology-3 replay trace recorded by T-127 (per second: `ev=tcp` srtt/sbbytes/retx and the video bytes from `net ev=stats`) has been copied by the orchestrator into this card's *Bağlam*. If T-127 records "fixed profile suffices", close this card as won't-do; T-178 is the answer.**

On Wi-Fi, full-screen changes push 100–450 KB per frame into the air. Control srtt rises from 20 to 60–100 ms and audio underruns, because only kernel *unsent* bytes are bounded and the bitrate is fixed per session. This card writes the decision logic only: a pure, fully unit-tested value type that turns per-frame and per-tick socket observations into "may I write a frame now?" and "what bitrate should the encoder target?". T-196 wires it in. Keeping the logic pure means it can be tuned against recorded T-127 traces without a device.

Source: external architecture review 2026-10-03 (H03); verification: docs/reviews/2026-10-03/verify-F-network.md.
Decision 0023 must be accepted by the user before work starts (branch (c), step 2).

## Bağlam

**Evidence (HEAD a30c769):**
- The video send gate looks at unsent bytes only: `SocketVideoTransport.swift:73-75` (`inFlight < 1` and `connection.isWritableForNewRecord`), which is `outbound.isEmpty && poll(POLLOUT)` under `TCP_NOTSENT_LOWAT` = 128 KiB (`BsdTcpSocket.swift:372-382`, `TransportKnobs.swift:98-113`). In-flight (unacked) bytes, srtt and cwnd are never consulted on the send path.
- NOTES 2026-10-02 ~13:20 (`docs/NOTES.md:970-991`): video `snd_cwnd` 2–13 MB, 100–450 KB in the air, control srtt 20→60–100 ms, 13 underruns in 5 min, no retransmits. The delay is AP/driver queueing behind bursts, not loss and not link capacity (raw link ~410 Mbit/s, `NOTES.md:603-610`; coverage audit K2).
- The input the controller can use already exists as a value type: `TcpConnectionSnapshot` in `host-mac/Sources/MateBridgeCore/Session/TcpInfoLog.swift:6-60` (`srttMs`, `sendBufferBytes` = `tcpi_snd_sbbytes`, retransmit counters). Do **not** use `unackedBytesEstimate` (`TcpInfoLog.swift:60-67`): it is `min(sbbytes, cwnd, snd_wnd)` and degenerates to `sbbytes` when cwnd is in the MB range (F A-5). Use `sendBufferBytes` (sbbytes) directly. `srttMs` has 1 ms resolution.
- Bitrate defaults: 30 Mbps at 60 fps full size, linear in fps (60 Mbps at 120 fps), clamped to 20–80 Mbps (`StreamPrefsPolicy.swift:21-27`). The ceiling the controller gets is the session's configured bitrate (0023: `STREAM_CONFIG.bitrate_kbps` becomes the ceiling).

**Shape (plan hints, from F F-2):**
- Inputs: per completed frame write (bytes, write start/done µs, keyframe flag); per 100 ms tick (`TcpConnectionSnapshot`, retransmit delta); per host-side queue drop.
- Outputs: (a) admission: whether a new frame may be written now, comparing `sbbytes` against an in-flight budget; (b) a target bitrate in [floor, ceiling].
- Baseline srtt = windowed minimum (e.g. 10 s). Budget ≈ target rate × 20 ms queue delay, floor = one average frame (so a single frame can always go).
- Fast-down: multiplicative (e.g. ×0.7), at most once per srtt, when srtt exceeds baseline by a threshold, sbbytes exceeds the budget, or a queue drop happens. Slow-up: additive (e.g. +5 % of ceiling per second) after a quiet period.
- Constants are `static let` with a comment naming T-127 as their source; T-196 may expose them through its knob only if needed.
- Pure: no clock reads, no logging, no Dispatch. Time comes in as arguments (µs), like other Core policies (`DisplayLease`, `KeyframeRequestCoalescer`).

**Golden replay.** Use the numbers-only topology-3 trace recorded by T-127 (copied into *Bağlam* before this card starts; raw logs are never committed, and the implementer has no device) as a Swift literal in `CongestionReplayTrace.swift`. `ev=tcp` is a 1 s window (`SessionServer.swift:312`, `tcpInfoTickInterval = 10`) with no per-frame bytes, so the trace has 1 s resolution: per second srtt, sbbytes, retx and video bytes. A Swift file avoids a `Package.swift` resource change (the test target declares no resources; `FixtureSupport.swift` reads protocol fixtures via `#filePath`, which would leave an unhandled-file warning for a raw CSV here). The test asserts the bitrate trace against a stored expected sequence.

**Risks.** Oscillation at constant RTT; reacting to srtt noise at 1 ms resolution on USB-like links (the controller is never used on loopback, T-196 decides that); a floor too low to carry a keyframe.

Wire: none. USB is unaffected (T-196 enables it on `transport=network` only).

## Kapsam dışı

- Wiring into `SocketVideoTransport`, the encoder or the session (T-196).
- The live encoder bitrate setter (T-177).
- Any client change, UDP/QUIC (0023 rejects it for now), write pacing inside a record.

## Kabul kriterleri

- [ ] [XCTest] Step response to a synthetic srtt spike: the target bitrate falls within one srtt of the spike, and recovers no faster than the configured slow-up slope.
- [ ] [XCTest] The target never goes above the ceiling or below the floor; a constant-RTT trace produces no oscillation (target settles and stays within ±1 step).
- [ ] [XCTest] Admission: with sbbytes above the budget, admission is refused; below, granted; the budget never drops below one average frame.
- [ ] [XCTest] A host-side queue drop triggers at most one fast-down per srtt.
- [ ] [XCTest] The golden replay from the T-127 trace matches the stored expected trace. The replay runs at 1 s resolution; sub-second behaviour is covered by the synthetic tests.
- [ ] No I/O, clock reads or logging in `CongestionController.swift`.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

**Kapatıldı, uygulanmadı (2026-10-04):** T-127 / 0023 dalı "sabit profil yeterli". Gecikme tablet Wi-Fi atlamasının patlama kuyruğu; ses Ethernet topolojisinde korunuyor. Mac Wi-Fi'ye dönülürse yeniden açılabilir (NOTES 2026-10-04 ~23:55).

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
