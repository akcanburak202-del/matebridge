---
id: T-152
title: Activate PAIRED sessions only after the first authenticated record
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-041]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-152-host-paired-proof-first.md
---

## Amaç

When no session is live, the Mac activates a PAIRED connection as soon as it sends its HELLO_ACK, before the peer has proved it holds the pair key. Anyone who has seen an approved tablet's `device_id` (sent in clear in HELLO) can therefore make the Mac create the virtual display, wake the displays and hold display sleep, every few seconds, indefinitely. This card applies the T-041 takeover proof rule to every PAIRED connection: the session starts, STREAM_CONFIG goes out and the display is built only after the first authenticated record. A real reconnect costs about one extra round trip.

Source: external architecture review 2026-10-03 (SE2, W3; A1 as a contract hole); verification: docs/reviews/2026-10-03/verify-A-security.md (additional issue A1, WI-3) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§3).

## Bağlam

`HC/` = `host-mac/Sources/MateBridgeCore/`. Lines are at HEAD a30c769 and were re-checked.

- **Evidence:**
  - `HC/Session/SessionMachine.swift:607-614`: PAIRED is chosen from `approvedDevices.contains(deviceID)` plus the stored key; `device_id` is the only client selector and is cleartext.
  - `continueHello` PAIRED branch `:649-668`: with a slot owner of the same device → `takeover = true` → `.proving` (:660-665). With **no** slot owner → `start()` directly (:666-667). `start()` (:726-735) sets `.active`, sends STREAM_CONFIG and emits `.sessionStarted` without any authenticated record.
  - `prove()` (:696-716) already handles "no slot owner" structurally (the supersede block is inside `if let owner = slotOwner`), then calls `start()` and processes the first record after activation (:713-714). It needs a test for the no-owner case, not a rewrite.
  - Side effects of `.sessionStarted` (`host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift:307-328`): sleep gate opens ("awake reason=session_started"), `displaySleep.hold()`, and `lease.sessionStarted` → display create (`HC/Video/DisplayLease.swift:37-47`) with attacker-chosen HELLO screen fields, i.e. display churn and window rearrangement. The attacker's session dies at the first bad record or after `closeSilenceUs` = 5 s (`SessionMachine.swift:85`), but the 10 s lease grace (`DisplayLease.swift:9`) means one HELLO every 5–10 s keeps a display alive and other devices get BUSY.
  - Bound: `awaitingHelloCount` already counts `.proving` (`SessionMachine.swift:220-228`), and `SessionServer` refuses new connections at `maxUnauthenticated = 4` (`host-mac/Sources/MateBridgeHost/Session/SessionServer.swift:304`, `:1127-1132`, `:1182-1187`). Today a non-takeover PAIRED connection skips that bound because it goes straight to `.active`.
  - The client already sends the proof PING first after ACCEPTED (`client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt:306`), then STREAM_PREFS (T-050), so no client change is needed.
- **Exposure:** none (verified by A2 §3): no input, video, clipboard or files without `pair_key`. This is an availability/power fix (Low/Medium).
- **Plan hints:** route both PAIRED cases through `.proving` with `proofTimeoutUs` (5 s, `:109`); the proving-deadline handling in `tick` (:500) closes an unproved connection. Keep the takeover path's behaviour and logs (`takeover_proving`) unchanged; add a distinct log reason for the non-takeover case only if useful (e.g. `paired_proving takeover=0`), listed under *Açık sorular* for `docs/LOGGING.md`.
- **PROTOCOL.md (orchestrator, before or at merge; prose only):** §3 step 3: "host her PAIRED bağlantıda ilk doğrulanmış kaydı bekler, sonra etkinleştirir ve STREAM_CONFIG gönderir". No message or fixture change.
- **Interaction with T-150:** none on the wire. A locally untrusted client (T-150) still sends PING, so the host proves and activates as usual.
- **Interaction with T-156:** after this card a wrong client key is never seen by the client as `AUTH_FAILED` on a host record: the host sends no record before the proof and closes **without BYE** at the bad proof (`recordAuthFailed`, `SessionMachine.swift:275-277`). T-156 counts that case (close after the proof PING, before any authenticated host record).
- **Known window (documented, not fixed):** `.proving` is not a slot owner (`slotOwner`, `SessionMachine.swift:575-580`). During a non-takeover proof (about 1 RTT) a PAIRING HELLO from another device can take the slot as pending, and the proving tablet is then answered BUSY at the proof (`prove()` :698-708). The window is tiny and the exposure already exists in no-session gaps; the test below pins the outcome.
- **Serialize with:** T-155 and T-171 (same file `SessionMachine.swift`; chain T-152 → T-155 → T-171). Host PING (T-171) must start only after activation.
- **Review:** security change: the orchestrator runs `./scripts/codex-review.sh`.

## Kapsam dışı

- Client changes; display-lease grace tuning (D4); USB-only listening (T-189); the orphan-approval guard (T-155).

## Kabul kriterleri

- [ ] [XCTest] Non-takeover PAIRED with no record: no `.sessionStarted`, no `.send(streamConfig)`; the connection is closed at `proofTimeoutUs`.
- [ ] [XCTest] Non-takeover PAIRED + a valid encrypted PING: `.sessionStarted`, then STREAM_CONFIG, then the pong for that PING, in that order.
- [ ] [XCTest] Non-takeover PAIRED + a record that fails authentication: closed, no `.sessionStarted`, no display-related action.
- [ ] [XCTest] Proving connections count toward the unauthenticated bound (`awaitingHelloCount`, `maxUnauthenticated` = 4).
- [ ] [XCTest] PAIRING HELLO from device B while device A's non-takeover PAIRED connection is proving: the outcome is pinned by a test and described in Handoff (expected today: B pending, A gets BUSY at its proof).
- [ ] [XCTest] Existing takeover and orphan tests pass unchanged.
- [ ] [device] A normal reconnect still shows video (about +1 RTT); `session_started` follows the first record in `host.log`.
- [ ] The orchestrator ran `./scripts/codex-review.sh` and its findings are resolved or recorded.
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
