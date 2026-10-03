---
id: T-196
title: Wire the congestion controller into the video gate and the encoder (Wi-Fi, knob)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-177, T-195]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Video/SocketVideoTransport.swift
  - host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-196-host-wifi-adaptive-send.md
---

## Amaç

**Gated: start only after (1) T-127 has recorded "go adaptive" in docs/NOTES.md (no fixed bitrate row meets all three budgets in topology 3: audio underruns ≤ 1 per 5 min, control srtt p95 ≤ 40 ms, client capture→decode p95 ≤ 70 ms), (2) T-195 is merged, and (3) T-177's device run shows VideoToolbox follows a live bitrate step (per-second bytes follow 60→15→60 Mbps within ≤ 1 s, no video reconnect). If (3) fails, only the admission half of this card is built and the bitrate half becomes an open question.**

This card puts T-195's controller on the real Wi-Fi send path behind a default-off knob: the `bsd` video gate also requires the controller's admission (bounding in-flight bytes, not only unsent ones), and the controller's target bitrate is applied live through T-177's setter instead of the restart path. The user gains a Wi-Fi stream that backs off during bursts and recovers sharpness when idle, with USB untouched.

Source: external architecture review 2026-10-03 (H03, X8); verification: docs/reviews/2026-10-03/verify-F-network.md.
Decision 0023 must be accepted by the user before work starts.

## Bağlam

**Evidence (HEAD a30c769):**
- Gate today: `SocketVideoTransport.swift:73-75` (`inFlight < SocketVideoGate.maxRecordsInFlight` and `connection.isWritableForNewRecord`); `isWritableForNewRecord` = `outbound.isEmpty && poll(POLLOUT)` (`BsdTcpSocket.swift:372-382`) under the 128 KiB `TCP_NOTSENT_LOWAT` (`SessionServer.swift:635`). Lock order: transport lock, then connection lock (comment at `SocketVideoTransport.swift:71-72`).
- Socket state reads: `TcpSocketProbe` (T-088) reads `TCP_CONNECTION_INFO` from a `BsdTcpConnection` directly (`TcpSocketProbe.swift:1-30`); the 1 s `ev=tcp` tick lives in `SessionServer` (T-126). `VideoLink` is at `SessionServer.swift:17`.
- Bitrate changes today restart capture and encoder (`StreamCoordinator.swift:373-389` → `restartPipeline` :564), which also costs a keyframe, so the restart path is unusable for adaptation (F H03.c). T-177 adds the live setter, routed through T-162's encoder owner queue.
- The session transport is known in the coordinator (`session?.transport`, `SessionTransport.network` vs `.usb`, `UsbTunnelPlanner.swift:102-106`).

**Plan hints (F F-3):**
- Knob `MATEBRIDGE_WIFI_ADAPT=1` (parse in `TransportKnobs.swift`), default off; active only on `transport == .network`. Add it to `docs/KNOBS.md` via *Açık sorular* (orchestrator, decision 0026 rules: default off, names this card).
- Sample sbbytes cheaply: on the write-completion queue or per tick, not inside every `canSend`. Keep `getsockopt` off the hot path if it is expensive.
- The double wake path (writable handler plus controller tick) must not lose a wake-up: a blocked admission must be re-checked on writable **and** on tick.
- Optional: write a large record in paced `write()` chunks (records cannot be split; pace the syscalls). Only if T-127/T-195 data says single keyframes are the problem.
- Mention F A-4 in Plan (non-audio H→C control ignores the low-water mark; low volume, not fixed here).
- Log `video ev=adapt` once per second while on: `target_kbps`, `sbbytes_p95`, `srtt_ms`, `admits_blocked`. Numbers only.

**Serialize with** T-189 (`SessionServer.swift`, chain T-163 → T-171 → T-186 → T-189 → T-196) and T-187 (`StreamCoordinator.swift`, chain T-165 → T-167 → T-187 → T-196 → T-200). T-200 waits for this card on `StreamCoordinator.swift`. `VideoPipeline.swift` is also edited by T-176/T-177 (T-177 is a dependency). After T-186 the `nw` path in `TcpSocketProbe` may be gone; read the file at start.

**PROTOCOL prose (orchestrator, not the implementer):** §0x03 `bitrate_kbps` "Hedef bit hızı" (`docs/PROTOCOL.md:154`) becomes "the ceiling the session was configured with; the host may encode below it under congestion without a new `config_id`". No bytes or fixtures change; `gen.py --check` stays green.

**Device procedure** reuses T-127's topology-3 workload (full-screen pan/scroll, Krita pinch, app switch, music, 5 min, ≥ 3 runs) with the knob on vs off, same build.

## Kapsam dışı

- USB sessions, UDP/QUIC, any client change.
- User `STREAM_PREFS` bitrate changes (they keep the restart path).
- Changing the controller's logic (T-195) beyond wiring; changing the 256 KiB control cap or audio low-water handling.

## Kabul kriterleri

- [ ] [XCTest] Knob off: gate behaviour is byte-identical to today (fake socket: same admit/refuse sequence, same records written).
- [ ] [XCTest] Knob on: admission blocks while the fake sbbytes exceeds the controller budget, and wakes on writable **or** on tick; no lost wake-up in an interleaving test.
- [ ] [XCTest] Knob parse: absent/invalid → off; on a `.usb` session the controller is never consulted.
- [ ] `video ev=adapt` once per second while on (fields above, numbers only); entry proposed for `docs/LOGGING.md`.
- [ ] [device] T-127 topology 3, knob on vs off, ≥ 3 runs each: audio underruns and control srtt p95 better than the baseline, client capture→decode p95 equal or better; static-text sharpness unchanged after 5 s idle (bitrate recovered). Results in NOTES with build IDs.
- [ ] [device] USB session with the knob set: no `ev=adapt` line, behaviour as today.
- [ ] Codex review (transport change) run and findings resolved.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
