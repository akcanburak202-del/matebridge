# Verifier A: Security, pairing trust, network/file scope (HEAD a30c769)

Scope: H01 (all sub-points), SE1, SE2, W3, M05 (all sub-points), X1, D2, the security part of D9, and the "trusted key from pending pairing" part of F2.

## Verdicts

### H01 — Pairing trust boundary on the tablet

- **Verdict: CONFIRMED.** The review understates two things: what an attacker can actually get, and how little they need. The current behaviour is deliberate and documented (PROTOCOL §9, T-044), so this is a design flaw, not an implementation bug.

**H01.Problem: the key is overwritten before any local confirmation.** Confirmed.
- `Handshake.kt:131-149` `ClientHandshake.complete`. For `KEY_PAIRING` it reads the stored key only to compute `rePairing = pairing && stored != null` (l.141). It then zeroes the stored key (l.144) and derives with `ikm = ecdh` only (l.142). The stored key is never used as a verification input.
- `Handshake.kt:67-77` `SecureSession.storePairKey` calls `store.put(hostId, newPairKey)`. `PairKeyStore.kt:38-41` `EncryptedPairKeyStore.put` writes the single `pairkey.<hostId>` entry in place. There is no pending slot, no delete, and no compare.
- `SessionController.kt:663-676`: in the reader thread, right after the first plaintext HELLO_ACK (`PENDING_APPROVAL`/`PAIRING`), `sec.storePairKey(keys)` runs before `Secured` is even posted. This is before the Mac decides and before the user does anything on the tablet. The code comment at l.665 states this is intended.
- PROTOCOL.md §9 ("Eşleşme" bullet 3 and "Bağlantı koptuktan sonra onay" item 1) and card T-044 (status done, accepted 2026-09-30) mandate exactly this: "hemen saklar (eskisinin yerine)".

**H01.Why: the SAS is only displayed.** Confirmed.
- `MainActivity.kt:2053-2070` `pairingText` shows the code and, for re-pairing, the amber line "Mac bu tableti tanımıyor, yeniden eşleşiliyor". The text says "Mac'te 'İzin ver' dediğinde bağlanır". There is no confirm or cancel control on the tablet.
- `SessionMachine.kt:300-326` `onAck`: an encrypted `HelloAck(ACCEPTED)` on the same connection moves to `Phase.ACCEPTED`. `inputAllowed` (l.166) becomes true. The machine immediately queues PING, STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS and FILES_INFO (l.306-311). No local condition is checked.
- The tablet therefore trusts any peer that completes an unauthenticated ECDH and then seals an ACCEPTED with its own keys.

**H01.Attack: what a fake host actually gets.** Confirmed, and wider than the review says.
1. **Same host_id is not needed to capture input.** Any endpoint the tablet connects to can answer `PENDING_APPROVAL/PAIRING` with any host_id and then send a sealed `ACCEPTED`. The tablet goes ACCEPTED with no user action.
   - The connection can happen without any user action. `MainActivity.kt:1803-1809` `onDiscovered` auto-connects to any `_matebridge._tcp` service found by NSD. The client stores no host_id to endpoint pin.
   - The tablet also reconnects automatically to the saved Wi-Fi IP (`lastWifiEndpoint`, T-134 direct wake connect).
   - Same host_id only matters for overwriting the stored key. The host_id is in clear in every first HELLO_ACK, so it is easy to copy.
   - The attacker can send ACCEPTED immediately, so the pairing-code screen may only flash.
2. **What the fake host receives after ACCEPTED:**
   - Every PEN, KEY, POINTER_*, SCROLL and PINCH message. KEY carries physical keycodes, enough to reconstruct typed text, including passwords the user types believing they are on the Mac.
   - Tablet clipboard copies made after acceptance. `SessionController.kt:367` gates on `inputAllowed`. ClipboardSync only sends copies newer than the baseline.
   - `FILES_INFO(READY, port, token)` if file sharing is on (`SessionMachine.kt:310`).
   - The attacker can also push CLIPBOARD *into* the tablet (`ClipboardBridge.kt:81-85` `setPrimaryClip`), send STREAM_CONFIG and video (a fake desktop for phishing), and send SETTINGS_OPEN and audio.
3. **The FILES_INFO token turns H01 into a file-access escalation for a local app.** This is new; the review missed it.
   - The DAV server listens on tablet `127.0.0.1` (`DavServer.kt:145-151`). Decision 0015 item 3 relies on the token being secret from other tablet apps.
   - The client's USB endpoint is `127.0.0.1:47001` (`ConnectMode.kt:14-18`). It is probed and connected in Auto/USB mode (`MainActivity.kt:1597-1615`, `1537-1548`).
   - Any app with INTERNET permission can bind `127.0.0.1:47001` whenever `adb reverse` is not active.
   - Attack chain: the app impersonates the Mac → the tablet auto-pairs → the app receives the token → the app gets read/write access to all of `/sdcard` (MANAGE_EXTERNAL_STORAGE scope) without ever being granted that permission.
   - A LAN fake host also receives the token but cannot reach tablet loopback.
4. **DoS.** The overwrite happens at the first ack, even if the attacker never sends ACCEPTED. On the next connection to the real Mac:
   - The Mac answers PAIRED with its key, and the tablet derives with the wrong key.
   - The first host record fails AEAD → `ProtocolError` → `lose(PROTOCOL_ERROR)` (`SessionMachine.kt:211-215`) → automatic retry, forever.
   - The user sees "protocol error / reconnecting", not "re-pair". The only recovery is "Onaylı cihazları unut" on the Mac.
   - Each failed retry also makes the Mac create the virtual display (see Additional issue A1).
5. **What the attacker cannot get.** The real Mac's key or the Mac's screen. A transparent relay needs Mac-side approval, and the Mac shows a different SAS. Passive sniffing is useless.

**Host-side questions.**
- **Does the host have its own approval?** Yes.
  - `SessionMachine.swift (Core):607-690`: an unknown device or missing key → `PENDING_APPROVAL` + `requestApproval` with SAS (`ApprovalPanel.swift:12-26`, 60 s live). There is also an orphan window: 2 min, the same code, and that handshake's key only (T-043 revision).
  - This approval protects only the Mac. In H01 the real Mac is not involved at all.
- **Can a fake TABLET replace the host's stored key for a known device_id?** No.
  - The host chooses PAIRED purely from its own state: `approvedDevices.contains(deviceID)` plus the key lookup (l.607-614). A client cannot request PAIRING.
  - A fake tablet with a sniffed device_id gets `ACCEPTED/PAIRED` sealed under a key it does not have, so it cannot produce a valid record.
  - Takeover of a live session needs the first authenticated record (`proving`, 5 s).
  - PAIRING for a known device happens only after "forget", host-identity replacement, or a missing key. It still needs a Mac-side click.
  - `persistingOrphans` → BUSY while an orphan approval is being stored (l.590-593).
  - Gap: a fresh, non-takeover PAIRED session is *activated before any proof* (A1). That is not key replacement, but it is a pre-auth side effect.

**H01.Where.** Confirmed. Line numbers are accurate to ±2: Handshake.kt 61-77 / 131-149; SessionController.kt 650-678 (the actual lines are 657-676); SessionMachine.kt 300-326. The tests that encode the old contract are:
- `CryptoVectorsTest.kt:233-245` (`rePairingIsFlaggedWhenAKeyExistsButTheMacAsksForPairing`, asserts `// replaced`)
- `SecureChannelTest.kt:113-119` (`aNewPairingReplacesTheOldKey`)
- `SecureChannelTest.kt:333-341` (store-level replace; harmless at store level)

**H01.Fix: needs a wire change?** **No.** The fix is client-local state and UI.
- No message, field or fixture changes, and `crypto_vectors.json` is unchanged.
- PROTOCOL.md **prose** must change (orchestrator): §3 step 3 (the client needs local confirmation before it treats ACCEPTED as accepted) and §9 "Eşleşme" bullets 1/3 and "Bağlantı koptuktan sonra onay" (1)/(3).
- The host is unchanged. It already tolerates a delay between ACCEPTED and STREAM_PREFS or video, because the client keeps sending PINGs (`SessionMachine.kt:358-368`, PINGs go out in PENDING/ACCEPTED).
- One correction to the review's fix: "persist only when both the local trust decision AND the protocol accept complete" conflicts with the orphan-approval flow the user relies on (NOTES 2026-09-30 l.253-255: see the code → switch to Parsec → approve on the Mac → return; the tablet never receives ACCEPTED). The workable rule:
  - Keep the new key in a **pending** record together with its SAS (wrapped, never logged).
  - Promote pending to trusted on **local confirmation**. That can happen before leaving for Parsec, or on return through a prompt that shows the stored code.
  - The *session* becomes ACCEPTED on the tablet only when the host's ACCEPTED (or a later PAIRED handshake) and the local confirmation are both present.
  - A PAIRED handshake must never use an unconfirmed pending key.
  - A Mac-side deny after a local confirm is harmless: the Mac then asks for PAIRING again.

**H01.Acceptance.** Agree. It is achievable with JVM tests: Handshake + SessionMachine + a scripted fake-host ack sequence. A device test is in X1.

- **Corrections:**
  1. A fake host does not need the same host_id to receive input; same host_id is only needed for overwrite/DoS.
  2. The behaviour is a documented design (PROTOCOL §9, T-044), so the fix also needs a decision record and a protocol-prose change.
  3. Missed impact: the FILES_INFO token goes to the fake host, so a local tablet app squatting `127.0.0.1:47001` gets full shared-storage access, which breaks the guarantee in decision 0015 item 3.
  4. Missed impact: host→tablet clipboard injection.
  5. The DoS shows up as an endless PROTOCOL_ERROR retry loop with no re-pair hint.
  6. The "persist when both complete" wording must be adapted to keep the orphan flow (see Fix).
- **Severity opinion:** High, agree. Not Critical, because it needs an active LAN attacker, mDNS/IP spoofing, or a malicious local app, and it gives no access to the real Mac. The local-app file-access path pushes it to the top of the High list.

### SE1 — Things to keep (crypto, storage, logging)

- **Verdict: CONFIRMED** (one minor correction).
- **Evidence:**
  - P-256 ECDH, transcript-bound HKDF, `ikm = pair_key ‖ ecdh` in PAIRED, and per-direction control and video keys: `Handshake.kt:136-149`, PROTOCOL §9, host `SessionMachine.swift:646-681`.
  - AES-GCM records with counter nonce and length AAD: `Records.kt`.
  - Separate video nonce and proof, nonce reuse rejected: host `SessionMachine.swift:379-414` (`videoNonces`, `maxVideoNonces=4096`, `proofTimeoutUs=5 s`).
  - Host keys in the Keychain: `MateBridgeHost/Security/KeychainPairKeyStore.swift`. Tablet keys wrapped by a non-exportable Keystore key with host_id as AAD: `PairKeyStore.kt:13-41`, `AndroidKeystoreWrapper.kt`.
  - `android:allowBackup="false"`: `AndroidManifest.xml:16`.
  - Logs carry no code, key or token: `SessionController.kt:392,408,437`; a grep of host `log(` calls found no code, key or token fields.
- **Corrections:** with `targetSdk = 31` (`build.gradle.kts:14`), `allowBackup=false` no longer blocks Android 12+ device-to-device transfer; that needs `dataExtractionRules`. The impact is small because migrated pair-key blobs cannot be unwrapped on another device (`get` → null → KEY_MISSING). The plain `device_id` would migrate, though. Whether HarmonyOS 4.3 performs D2D transfer cannot be verified here.
- **Severity opinion:** n/a (positive finding). The D2D point is Low.

### SE2 — Pre-auth hardening; no unauthenticated path to Mac control

- **Verdict: PARTIALLY CORRECT.**
- **Evidence:**
  - Size checks: client `PlainFrames.read` checks the length before reading (`Handshake.kt:158-164`); the host enforces `maxPendingRecords/Bytes` and a 64-byte video-proof decoder (`SessionServer.swift:1470`).
  - Timeouts: HELLO 5 s, approval 60 s, proof 5 s, video HELLO 5 s, lookup timeout (`SessionMachine.swift:82-109`).
  - Unauthenticated connection limit: `SessionServer.swift:304` `maxUnauthenticated = 4`, enforced at l.1127-1184.
  - Input before ACCEPTED is ignored: `SessionMachine.swift:749-752`.
  - "Old PSK doesn't give access to the real Mac" is correct: the fake-host `new_pair_key` comes from the attacker's own ECDH.
- **Corrections:**
  1. The review states the pre-approval guard only for the Mac. The tablet has no equivalent guard (H01).
  2. Missed: a **non-takeover PAIRED connection is activated before any authenticated record** (A1). An attacker who knows a paired `device_id` (sent in clear in HELLO) can make the Mac create or keep the virtual display, open the sleep gate, and hold a display assertion, repeatedly. This is not control of the Mac, but it is a pre-auth side effect. `maxUnauthenticated` does not count these sessions, because they go straight to `.active`.
- **Severity opinion:** agree there is no proven path to Mac control without auth. A1 is Low/Medium (DoS or keep-awake).

### W3 — USB tunnel, discovery, generations, proofs

- **Verdict: PARTIALLY CORRECT.**
- **Evidence:**
  - USB uses the same protocol and encryption over `adb reverse` to `127.0.0.1:47001` (`ConnectMode.kt:14-22`, decision 0010 item 4).
  - Endpoints come from Bonjour (`MacDiscovery.kt`), manual entry, or saved values (`settings.lastEndpoint()`, `MainActivity.kt:465`; `lastWifiEndpoint`).
  - Connection generations: client `SessionMachine` `controlGen/videoGen`, `trySendInput(gen)` at `SessionController.kt:285-290`.
  - Takeover proof: host `SessionMachine.swift:646-662`. Video proof and nonce: l.379-414.
- **Corrections:**
  - "Proven peer keys limit channel takeover" holds for **takeover of a live session** and for video only. A fresh PAIRED session is activated without proof (A1).
  - The tablet never authenticates the *host* during PAIRING (H01).
  - Endpoints are not bound to a host_id, so whatever answers the discovered or saved address or the USB loopback port is accepted.
- **Severity opinion:** n/a (descriptive claim).

### M05 — Access scope can be narrowed

- **Verdict: CONFIRMED**, including the review's own "Limit" paragraph, plus one aggravating factor through H01.

**Network scope.** Confirmed.
- `BsdTcpListener` binds `[::]` with `IPV6_V6ONLY=0` by default (`BsdTcpSocket.swift:72-141`; `.loopbackV6`/`.loopbackV4Mapped` exist only for tests).
- The production callers use the default: control `SessionServer.swift:1031` and video `:639`. The NW path (`:600`, `:987-990`) also listens on every interface and always attaches the Bonjour service.
- There is no USB-only or interface setting on the host. A grep of host sources for usbOnly/loopback-bind found nothing.
- USB sessions arrive from a loopback peer (`SessionServer.swift:1635-1640`), so a loopback-only profile would work with `adb reverse`.

**File scope.** Confirmed.
- `FilesController.kt:83-85` roots `DavServer` at `Environment.getExternalStorageDirectory()`; `AndroidManifest.xml:8-11` requests `MANAGE_EXTERNAL_STORAGE`.
- There is no folder choice and no read-only mode. Sharing is off by default (`Settings.kt:51`, `"1"` only).
- This is a deliberate choice (decision 0015 item 1).

**Limit paragraph.** Correct.
- DAV binds `127.0.0.1` only (`DavServer.kt:145-151`).
- A new 128-bit token is generated per server start (`FilesController.kt:79-80`); the Mac mounts through `adb forward` with the token kept in memory (`TabletFilesBridge.swift:8-11,160-183`).
- Canonical and symlink checks: `DavPath.kt:107-185`. Connection limit: T-139.
- An earlier LAN exposure is already fixed: the adb server listening on `*:5037` (NOTES l.249, T-039).

**Fix and Acceptance.** Reasonable. A USB-only profile is a host-local change: bind `.loopbackV4Mapped`/`::1`, no Bonjour, and reject non-loopback peers. It needs no wire change.

- **Corrections:**
  1. Missed: the DAV server runs whenever the activity is in the foreground and the setting is on (`FilesController.kt:39-47`, `FilesSwitch.shouldRun`). It does not depend on an accepted USB session, so the token-protected endpoint is reachable by local apps most of the time.
  2. Missed: the token's secrecy is undermined by H01 (fake host or local squatter receives FILES_INFO), which is the realistic path to unauthorised file access. Fixing H01 matters more than narrowing the folder.
  3. "Pairing approvals limited to a short user window": today the host raises an approval dialog for *any* unknown device_id at any time while no session is active. A new PAIRING request also silently replaces an open orphan window (`SessionMachine.swift:683-687`). The user, back from Parsec, may then click "İzin ver" on an attacker's request whose name they control. The SAS comparison still protects, but only if the user re-compares.
- **Severity opinion:** Medium, agree. The network part is Low on a home LAN; the file part is Medium because of the H01 coupling.

### X1 — Trusted-host re-pair acceptance scenario

- **Verdict: CONFIRMED.** The test is needed, and it would fail at HEAD.
  - A fake `KEY_PAIRING` with a known host_id replaces the key (`CryptoVectorsTest.kt:233-245` asserts exactly that).
  - A sealed ACCEPTED opens input and clipboard (`SessionMachine.kt:300-317`, `SessionController.kt:367`).
  - The tablet has no cancel action, and no "forget this Mac" action exists (`PairKeyStore` has no remove).
- **Corrections:**
  1. On the device, the "fake host with the same host_id" case is reproduced exactly by using the real Mac's "Onaylı cihazları unut". On the wire this is identical to a fake host: same host_id, PAIRING. No special tooling is needed for the trust-transition part.
  2. A different-host_id fake (a second host instance, or a scripted JVM fake) covers the "new host must be user-initiated" path.
  3. Most of X1 is JVM-testable at the Handshake/SessionMachine/PairKeyStore level.
- **Severity opinion:** n/a (test proposal). It should be the merge gate for the H01 cards.

### D2 — Close H01 first (re-trust on tablet, pending/trusted, negative test as merge gate)

- **Verdict: PARTIALLY CORRECT.** The direction is right, with two amendments.
- **Evidence:** as in H01. There is no pending/trusted split in `PairKeyStore.kt` and no local confirmation in `SessionMachine.kt`.
- **Corrections:**
  1. The commit point must be the **local confirmation**, not "local confirmation + protocol ACCEPTED". Otherwise the Parsec/orphan flow that is in daily use breaks (T-043/T-044, NOTES 2026-09-30). The session gate, not the key commit, needs both.
  2. "Merge gate" means `./scripts/check.sh` (the JVM tests). No CI exists (P4), so the gate is procedural.
  3. Add: withhold FILES_INFO and ignore inbound CLIPBOARD until the session is locally trusted, and add a "Bu Mac'i unut" action on the tablet.
- **Severity opinion:** agree it is the first item to close.

### D9 (security part, M05 scope) — USB-only/LAN scope, narrow file permission

- **Verdict: CONFIRMED** for the security sub-items. There is no USB-only profile and no narrow file scope, as M05 shows. The setup, runbook and factory-reset sub-items are outside this verifier's scope.
- **Corrections:** the order should be H01 → file-scope/token-lifetime → USB-only bind. The adb `-a` exposure is already closed (T-039).
- **Severity opinion:** Medium for the file scope, Low for the network scope.

### F2 (part) — Trusted key must be separated from pending pairing

- **Verdict: CONFIRMED.**
- **Evidence:** one store entry per host_id (`PairKeyStore.kt:38-43`), written at the first PAIRING ack (`SessionController.kt:666`). `SessionSecrets.pairing` and `SecureSession.rePairing` (`Handshake.kt:22-58`) are the only "pending" notion, and they are in memory per connection.
- **Corrections:** a narrow change is enough. It touches `security/` and the session gate; there is no transport refactor and no wire change.
- **Severity opinion:** agree (it is the H01 fix).

## Additional issues found

**A1. Host activates a non-takeover PAIRED session before any key proof.** Low/Medium.
- `SessionMachine.swift (Core):646-662`: when no session is live, the PAIRED branch calls `start()` directly (l.726-735). That emits `.sessionStarted`, so the session counts as active before any authenticated record arrives. Only takeover goes through `.proving`.
- `.sessionStarted` reaches `StreamCoordinator.onSessionStarted` (`StreamCoordinator.swift:306-328`): sleep gate "awake reason=session_started", `displaySleep.hold()`, and `lease.sessionStarted` → `.create(settings)` (`DisplayLease.swift:37-41`). The settings come from the attacker-supplied HELLO screen fields (`makeStreamConfig(hello)`).
- An attacker who has seen one plaintext HELLO (device_id) can repeat this every few seconds. The session ends at heartbeat timeout (5 s) or immediately on a bad record. Each attempt creates or keeps a virtual display, wakes the displays, and blocks display sleep.
- Card T-041 (l.77) only proved "kanıtsız B hiçbir sessionStarted üretmez" for takeover.
- The fix is host-local and needs no wire change: always enter `.proving` for PAIRED. The client already sends the proof PING first (`SessionMachine.kt:305`). PROTOCOL §3 prose needs updating.
- This also caps the H01 DoS loop's side effect (a display is created per retry).

**A2. No "forget this Mac" on the tablet.** Low.
- `PairKeyStore` has no `remove` (`PairKeyStore.kt:6-11`), and there is no UI action. Recovery from a corrupted pairing (H01 DoS) is only possible from the Mac menu.

**A3. Endless PROTOCOL_ERROR retry loop on a key mismatch.** Low.
- A PAIRED handshake whose first host record fails AEAD is handled like any protocol error (`SessionMachine.kt:211-215` → `lose` → retry). The user gets no "key mismatch / re-pair" state. After the H01 fix, the realistic remaining cause is the Mac losing its Keychain item. A distinct UI cause after N consecutive AEAD failures on PAIRED would help.

**A4. DAV server lifetime is wider than its use.** Low.
- It runs whenever the app is in the foreground and sharing is on (`FilesController.kt:39-47`), not only while an ACCEPTED USB session exists. The token is per start, but the listener is reachable by every local app for that whole time.

**A5. allowBackup does not cover D2D on targetSdk 31.** Low; device behaviour not verifiable here.
- `AndroidManifest.xml:16` together with `build.gradle.kts:14`. Add `android:dataExtractionRules` excluding the prefs, or accept and document it. Keys stay safe because they are Keystore-wrapped.

**A6. A new PAIRING request replaces an open orphan approval window.** Low.
- `SessionMachine.swift:683-687`. Any LAN device sending a HELLO with a fresh device_id while the user is in Parsec swaps the dialog. The new dialog has a new code and an attacker-chosen name.
- The SAS still protects, but this is approval-fatigue surface. A short "pairing mode" window on the host, or a visible "this is a different request" note, would reduce it.

**A7. MainActivity accepts many debug/perf extras from any launcher intent.** Low/informational.
- `MainActivity.kt:295-495`; the activity is exported as the launcher. None of the extras sets an endpoint (`transport` only picks wifi/usb), so there is no security impact found. Noted only because the extras ship in release builds.

## Proposed work items

### WI-1 (H01-core): Tablet: keep the new pair key pending until the user confirms the code; gate ACCEPTED on local trust

- **owner:** android-client-dev
- **depends_on:** [T-042, T-044], WI-0 (decision and PROTOCOL prose by the orchestrator)
- **decision record:** yes (WI-0)
- **wire protocol change:** **none.** No message, field, fixture or crypto-vector change. PROTOCOL.md prose changes in §3 step 3 and §9 are done by the orchestrator in WI-0.
- **files:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/security/` (Handshake.kt, PairKeyStore.kt)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt`, `SessionController.kt`, `SessionUi.kt`, `Settings.kt` (KeyValueStore: add `remove` / multi-key commit if needed)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/security/`, `client-android/app/src/test/kotlin/dev/matebridge/client/session/`
  - the card
- **Goal:** a PAIRING answer, whether for a new or a known host_id, must never change the trusted key or open input, clipboard or files until the user has confirmed on the tablet that the codes match. The new key is kept as a *pending* record (key + SAS, Keystore-wrapped), separate from the trusted key. Local confirmation promotes it atomically. Cancel, timeout or disconnect leaves the trusted key untouched. Normal PAIRED reconnects stay silent.
- **Out of scope:** the UI buttons and prompts (WI-2), host changes, and any wire change.
- **Acceptance criteria (all JVM):**
  - [ ] Stored host_id key K + `KEY_PAIRING` first ack + sealed `ACCEPTED`: K is unchanged, `inputAllowed == false`, no FILES_INFO, STREAM_PREFS or input is queued, and inbound CLIPBOARD is not delivered. Only PINGs go out.
  - [ ] The same with an unknown host_id: no trusted key is created, and the session is not ACCEPTED.
  - [ ] Local confirm, then host ACCEPTED (and the reverse order): the pending key is promoted (trusted = new key, pending removed), and the session goes ACCEPTED with the existing action order (PING, STREAM_PREFS, ...). A STREAM_CONFIG that arrived before the confirmation is applied after it (buffer the latest).
  - [ ] Drop during approval, then local confirm on return (pending still present), then the next connection is PAIRED: it is completed with the promoted key (orphan flow, T-043/T-044).
  - [ ] Cancel, local-confirm timeout (e.g. 2 min), or a REJECTED: pending is deleted and trusted is unchanged.
  - [ ] A PAIRED handshake never uses an unconfirmed pending key.
  - [ ] A promotion that fails to persist leads to `KEY_STORE_FAILED` (as today); the trusted key is not half-written.
  - [ ] SAS and keys are never logged (MbLog grep test).
  - [ ] Replace the old-contract tests: `CryptoVectorsTest.kt:233-245` and `SecureChannelTest.kt:113-119` now assert "not replaced before confirmation".
  - [ ] Migration candidates still never store or pend (existing `candidateKeys`).
  - [ ] `./scripts/check.sh` passes.
- **Plan hints:**
  - Add `PendingPairStore` (or extend `PairKeyStore` with `getPending/putPending/promote/dropPending/remove`), with entry `pairpend.<hostId>` = wrap(key ‖ sas, aad = hostId ‖ "pending").
  - `storePairKey` becomes `storePending`. `SessionController.kt:663-670` keeps the timing (first ack) but writes pending.
  - Machine: new `Phase.HOST_ACCEPTED_UNTRUSTED` (or flags `hostAccepted`, `locallyTrusted`). `inputAllowed` requires both. Add events `TrustConfirmed(gen)` and `TrustCancelled(gen)`. Keep PINGs running so the host heartbeat (5 s) is not hit.
  - Risk: the host sends STREAM_CONFIG once at ACCEPTED (`onConfig` currently drops it when not ACCEPTED, `SessionMachine.kt:340-341`), so it must be buffered.
  - Verify that the host does not time out a session that does not open video for a while. No such watchdog was found, but confirm in WI-4 on the device.

### WI-2 (H01-UI): Tablet: confirm/cancel buttons for the pairing code, re-trust prompt, and "Bu Mac'i unut"

- **owner:** android-client-dev
- **depends_on:** WI-1 (merge together)
- **decision record:** covered by WI-0
- **wire protocol change:** none
- **files:** `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt` (pairing screen only), `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionUi.kt`, the card
- **Goal:** the pairing screen gets "Kodlar aynı — Güven" and "İptal". For a known host_id it shows a distinct warning ("Bu Mac'in kimliği/anahtarı değişti. Kodu Mac'teki ile karşılaştırmadan onaylama"). When the app returns with an unconfirmed pending record, it shows the stored code with the same two buttons. A settings action "Bu Mac'i unut" removes the trusted key for the last host_id after an explicit confirmation.
- **Out of scope:** state logic (WI-1) and Mac UI.
- **Acceptance criteria:**
  - [ ] JVM: the UI-state mapping, e.g. `SessionUi.AwaitingApproval` gains `needsLocalConfirm`.
  - [ ] Device: the steps in WI-4.
  - [ ] The Parsec hint text is updated: "Kodu tabletteki ile karşılaştır, Mac'te İzin ver, buraya dönüp 'Kodlar aynı'ya bas".
  - [ ] `./scripts/check.sh` passes.
- **Plan hints:**
  - The `pairingText` builder is at `MainActivity.kt:2053-2070`. Buttons post `controller.confirmTrust()` / `cancelTrust()`.
  - AutoTransport treats AwaitingApproval as `WAITING_USER` (`AutoTransport.kt:245`), so check that it still holds while waiting for the local confirm.

### WI-0 (H01-doc): Decision record and PROTOCOL prose for tablet-side trust confirmation

- **owner:** orchestrator
- **depends_on:** []
- **decision record:** yes, "0018 — Tablet-side trust confirmation for pairing". Draft:
  > Decision 0010 assumed the SAS comparison protects both sides, but only the Mac enforced it. The tablet stored the new key at the first PAIRING ack (T-044) and accepted any sealed ACCEPTED, so any endpoint that answers PAIRING (LAN mDNS/IP spoof, or a local app on `127.0.0.1:47001`) received input, clipboard and the FILES_INFO token, and could overwrite the stored key for a known host_id. Decision: the tablet keeps a new pair key as *pending* (key + SAS) until the user confirms the code on the tablet. Confirmation promotes it atomically. The tablet treats the session as accepted only when the host's ACCEPTED (or a PAIRED handshake) and the local confirmation are both present. Cancel, timeout or REJECTED drop the pending key and keep the trusted one. Normal PAIRED reconnects are unchanged. The orphan flow (T-043/T-044) is kept: the confirmation may happen before or after leaving the app. No wire change. Amends 0010 (Consequences) and the client-side text of PROTOCOL §9.
- **wire protocol change:** prose only. §3 step 3 (PENDING → ACCEPTED: the client also needs local confirmation before sending anything but PING) and §9 "Eşleşme" bullets 1/3 and "Bağlantı koptuktan sonra onay" (1)/(3). No messages, fields or fixtures change.
- **files:** `docs/decisions/0018-*.md`, `docs/PROTOCOL.md`, `docs/decisions/0010-session-encryption.md` (status note only)
- **Acceptance criteria:**
  - [ ] The decision is merged before WI-1 starts.
  - [ ] `python3 protocol/fixtures/gen.py --check` is unchanged and green.

### WI-3 (A1): Mac: activate a PAIRED session only after the first authenticated record (also when not a takeover)

- **owner:** mac-host-dev
- **depends_on:** [T-041]
- **decision record:** no. It applies the T-041 proof rule uniformly. PROTOCOL §3 prose is updated by the orchestrator.
- **wire protocol change:** none. The client already sends PING first after ACCEPTED (`SessionMachine.kt:305`). Prose in §3 step 3: "host her PAIRED bağlantıda ilk doğrulanmış kaydı bekler, sonra etkinleştirir ve STREAM_CONFIG gönderir".
- **files:** `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift`, `host-mac/Tests/MateBridgeCoreTests/`, the card
- **Goal:** today a HELLO with a known device_id from a peer without the key makes the Mac create the virtual display, wake displays and hold display sleep for about 5 s, and this can be repeated. Route every PAIRED answer through `.proving`, so that `sessionStarted`, STREAM_CONFIG and display work happen only after the first valid record.
- **Out of scope:** client changes and display-lease grace tuning.
- **Acceptance criteria (XCTest):**
  - [ ] Non-takeover PAIRED + no record → no `.sessionStarted` and no `.send(streamConfig)`; closed at `proofTimeoutUs`.
  - [ ] PAIRED + valid PING → `.sessionStarted`, then STREAM_CONFIG, then the PING is processed (pong).
  - [ ] Proving connections count toward `maxUnauthenticated`.
  - [ ] Existing takeover tests pass unchanged.
  - [ ] Device: a normal reconnect still shows video (adds about 1 RTT).
  - [ ] `./scripts/check.sh` passes.
- **Plan hints:**
  - `continueHello` PAIRED branch (`SessionMachine.swift:646-662`): use `.proving` for both cases. `prove()` must handle "no slot owner".
  - Risk: the client's 2nd message is STREAM_PREFS. `prove` must process the first record *after* activation, which it already does for takeover.

### WI-4 (X1): Device acceptance procedure for the trust transition

- **owner:** orchestrator (device), then user
- **depends_on:** WI-1, WI-2, WI-3
- **wire protocol change:** none
- **files:** `docs/NOTES.md` (results), the card
- **Procedure:**
  1. **Paired baseline:** reconnect is silent PAIRED (`mode=paired`).
  2. **Fake same-host_id:** on the Mac, "Onaylı cihazları unut" (this produces a PAIRING with the same host_id). On the tablet, "İptal".
     - Check that `pair_key_stored` is not logged and that no input reaches the Mac.
     - Then on the Mac "İzin ver" without confirming on the tablet: the tablet stays unaccepted and nothing is injected.
  3. **Real re-pair:** confirm on both sides and the session works.
  4. **Orphan flow:** see the code → Home/Parsec → İzin ver on the Mac → return → confirm prompt with the same code → PAIRED.
  5. **New host:** a second host instance (other Mac, or same Mac under a different user with its own identity) advertises. The tablet must not become ACCEPTED without local confirmation.
  6. **Local squatter (optional, debug build only):** start `nc -l 127.0.0.1 47001` style listener app/`adb shell` with reverse removed. The tablet must not send FILES_INFO.
- **Acceptance criteria:**
  - [ ] Every step is logged in NOTES with the log events.
  - [ ] No key, SAS or token appears in any log.

### WI-5 (M05-host): Mac: USB-only network profile

- **owner:** mac-host-dev
- **depends_on:** []
- **decision record:** yes (short). Draft:
  > The host can run in "Yalnız USB" mode: control and video listeners bind loopback only, Bonjour is not advertised, and non-loopback peers are refused at accept. The default stays "USB + Wi-Fi". Rationale: in daily USB use the LAN listening and pairing surface is unnecessary. Wi-Fi fallback and wake flows (T-133/T-134) are unavailable in this mode, and the client shows the existing USB hint.
- **wire protocol change:** none. PROTOCOL §3.1 gets a note that Bonjour may be absent in USB-only mode.
- **files:** `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`, `host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift` (already has loopback cases), `host-mac/Sources/MateBridgeHost/Session/UserDefaultsStreamPrefsStore.swift` or a new small prefs file, `host-mac/Sources/MateBridgeApp/main.swift` (menu toggle), `host-mac/Tests/MateBridgeCoreTests/`, the card
- **Goal:** let the user close the LAN surface when only USB is used.
- **Out of scope:** per-interface selection and automatic LAN profiles (later, if wanted).
- **Acceptance criteria:**
  - [ ] XCTest: a `.loopbackV4Mapped` listener refuses a connect to the LAN address. A peer-classification test rejects non-loopback in USB-only mode.
  - [ ] Device: in USB-only mode, `lsof -iTCP -sTCP:LISTEN` shows 47001/47002 on 127.0.0.1/::1 only, `dns-sd -B _matebridge._tcp` shows nothing, and the USB session works.
  - [ ] Switching the mode restarts the listeners cleanly while no session is live.
  - [ ] `./scripts/check.sh` passes.
- **Plan hints:**
  - Listener creation: bsd at `SessionServer.swift:639`, `:1031`; nw at `:600`, `:987` (use `requiredInterfaceType = .loopback` or skip nw in this mode). Bonjour: `listener.service` and `BonjourAdvertiser`.

### WI-6 (M05-client): Tablet: narrow the file-sharing scope and lifetime

- **owner:** android-client-dev
- **depends_on:** WI-1 (token secrecy first)
- **decision record:** yes (amends 0015 item 1). Draft:
  > Tablet file sharing defaults to a user-chosen folder under shared storage (default: Download/ or a "MateBridge" folder), with an optional "tüm depolama" choice and an optional read-only mode. The server starts only while an accepted USB session exists and stops when it ends. The FILES_INFO semantics are unchanged.
- **wire protocol change:** none (FILES_INFO is unchanged; the server's start/stop timing changes but is already allowed by §4 0x09).
- **files:** `client-android/app/src/main/kotlin/dev/matebridge/client/files/` (FilesController.kt, FilesSwitch.kt, FilesConfig.kt, DavHandler.kt for read-only), `client-android/app/src/main/kotlin/dev/matebridge/client/settings/` (setting), `client-android/app/src/test/kotlin/dev/matebridge/client/files/`, the card
- **Goal:** an approved Mac should reach only the folder the user chose. The token-protected listener should exist only while it is useful.
- **Out of scope:** SAF/DocumentsProvider rewrite, and Mac-side mount changes.
- **Acceptance criteria:**
  - [ ] JVM: a root other than `/sdcard` is honoured. Path, encoding and symlink escapes outside the chosen root are refused (extend the DavPath tests).
  - [ ] JVM: read-only mode rejects PUT/DELETE/MKCOL/MOVE/COPY/LOCK with 403.
  - [ ] `FilesSwitch.shouldRun` requires "accepted && transport == USB".
  - [ ] Device: the Finder mount shows only the chosen folder. Disconnecting USB stops the server (`state=off`).
  - [ ] `./scripts/check.sh` passes.
- **Plan hints:**
  - Root at `FilesController.kt:83-85`. Lifetime at `FilesController.sync` (`:39-47`); it needs the session-accepted and transport signal from MainActivity (add MainActivity to `files:` for that one call site). MANAGE_EXTERNAL_STORAGE is still needed for path access to a subfolder.

### WI-7 (A3, optional): Tablet: show "Mac anahtarı uyuşmuyor" after repeated PAIRED AEAD failures

- **owner:** android-client-dev
- **depends_on:** WI-1, WI-2
- **wire protocol change:** none
- **files:** `client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt`, `SessionUi.kt`, `SessionController.kt`, tests, the card
- **Goal:** replace the silent endless PROTOCOL_ERROR loop with a terminal state that points to "Bu Mac'i unut" (tablet) or "Onaylı cihazları unut" (Mac).
- **Acceptance criteria:**
  - [ ] JVM: three consecutive record-auth failures on PAIRED connections → `Failed(KEY_MISMATCH)`.
  - [ ] A single failure still retries.
  - [ ] `./scripts/check.sh` passes.

## Coverage

| Claim ID | Verdict entry present |
|---|---|
| H01 (Problem, Why, Attack, Where, Fix, Acceptance) | yes: CONFIRMED, each sub-point covered |
| SE1 | yes: CONFIRMED (minor D2D correction) |
| SE2 | yes: PARTIALLY CORRECT |
| W3 | yes: PARTIALLY CORRECT |
| M05 (Problem/Impact, Limit, Fix, Acceptance) | yes: CONFIRMED |
| X1 | yes: CONFIRMED |
| D2 | yes: PARTIALLY CORRECT |
| D9 (security / M05 part) | yes: CONFIRMED |
| F2 (trusted key vs pending pairing part) | yes: CONFIRMED |
