---
id: T-150
title: Keep new pair keys pending until local confirmation; pair only on user action; gate migration promotion on an authenticated record
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-042, T-044]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Handshake.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/PairKeyStore.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionUi.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/AutoTransport.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Wol.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/security/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-150-client-pending-pair-trust.md
---

## Amaç

Today the tablet trusts any endpoint that answers PAIRING: it overwrites the stored pair key at the first PAIRING ack and opens input, clipboard (both ways), audio and the FILES_INFO WebDAV token as soon as a sealed ACCEPTED arrives, with no local check. A fake Mac found by Bonjour, anyone answering at the remembered IP, or a tablet app squatting `127.0.0.1:47001` therefore gets every keystroke (passwords included) and full read/write access to shared storage, and a same-`host_id` impostor locks the real Mac out in an endless PROTOCOL_ERROR loop. This card moves the trust decision onto the tablet: a new key stays **pending** until the user confirms the code, the session opens only when the host accepted **and** the key is locally trusted, pairing only ever starts from a user action, and an AUTO-mode USB migration candidate is promoted only after the host proves the key. This is the core security fix of D2.

Source: external architecture review 2026-10-03 (H01, X1, D2, F2, SE2, W3, A2(iii)); verification: docs/reviews/2026-10-03/verify-A-security.md (H01, WI-1) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§1–2, migration side finding); coverage audit §3 A2(iii) and §4.7.
Decision 0018 must be accepted by the user before work starts (manifest §5 Q3).
Gated: start only after the orchestrator has merged decision 0018 and the PROTOCOL.md §3 step 3 / §9 prose.
**T-150 and T-151 must merge back-to-back; do not install an APK between them.** T-150 alone makes every PAIRING answer abort (all `start` callers default to `userInitiated = false`), and the UI that lets the user pair again arrives in T-151.

## Bağlam

`C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`. Lines are at HEAD a30c769 and were re-checked.

**Evidence: the key is overwritten before any local step**
- `C/security/Handshake.kt:131-149` `ClientHandshake.complete`: for `KEY_PAIRING` the stored key only sets `rePairing` (:141). It is not an input to the KDF (:142) and is zeroed (:144).
- `Handshake.kt:67-77` `SecureSession.storePairKey` → `store.put(hostId, newPairKey)`, once, no compare. `C/security/PairKeyStore.kt:38-41` writes the single `pairkey.<hostIdHex>` entry in place. There is no pending slot, no `remove`, no compare.
- `C/session/SessionController.kt:662-677` (reader thread): `storePairKey` runs right after the first plaintext PENDING ack (:666, comment :665 says this is intended), **before** `Secured` (:676) and `Received` (:677) are posted. No UI or user step comes first.
- PROTOCOL.md §9 "Eşleşme" bullet 3 and "Bağlantı koptuktan sonra onay" (1) mandate exactly this ("hemen saklar (eskisinin yerine)"), as does T-044. It is a design flaw, not a bug.

**Evidence: a sealed ACCEPTED opens everything**
- The fake host did the ECDH, so it holds `controlH2c` and can seal ACCEPTED. `C/session/SessionMachine.kt:299-320` `onAck(ACCEPTED)` queues PING, STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS and FILES_INFO (:306-310), sets `Phase.ACCEPTED` (:316) and emits `Connected` (:317). `inputAllowed` (:166) becomes true.
- Input: `SessionController.trySend`/`trySendInput` gate only on `inputAllowed` (:278-295). Inbound CLIPBOARD: `SessionController.kt:367` (gated only on `inputAllowed`) → `setPrimaryClip`. Outbound clipboard follows `render(Connected)` (`C/MainActivity.kt:1860-1863`). SETTINGS_OPEN: `SessionMachine.kt:283`.
- Audio: AUDIO_CONFIG/AUDIO_FRAME go from the reader straight to the listener with no acceptance check at all (`SessionController.kt:728-737`, `deliverAudio` :748-758). A fake host can play audio on the tablet even before ACCEPTED.
- The SAS is display-only: `MainActivity.kt:2053-2070` `pairingText` has no button; `SessionUi.AwaitingApproval` (`C/session/SessionUi.kt:12`) has no confirm state.

**Failure scenarios this card must close (A, A2)**
1. **Auto-discovered fake host.** On the Wi-Fi path (WIFI mode, or AUTO after the USB probe closed; `MainActivity.kt:1513-1537`), `MacDiscovery` connects to every resolved `_matebridge._tcp` IPv4 service (`C/session/MacDiscovery.kt:105-122`) and `onDiscovered` calls `connect(ep)` whenever the tablet is Searching or Disconnected (`MainActivity.kt:1803-1809`; `C/session/WakeConnect.kt:127-134`). The remembered `lastWifiEndpoint` is retried directly (`MainActivity.kt:274`, `:1536`). The attacker sends PENDING(PAIRING) and a sealed ACCEPTED in one write, with any `host_id`; the code screen flashes or never paints; the tablet shows "connected" to the attacker's `hostName`. Nothing appears on the Mac.
2. **Localhost squatter gets the WebDAV token** (A2 §2). In AUTO (the default) an un-gated TCP probe to `127.0.0.1:47001` runs on every `applyTransport` (`MainActivity.kt:1524`, `:1597-1625`; OPEN → `startUsb` :1632-1634) and USB mode always connects there (`:1540-1548`; `C/session/ConnectMode.kt:14-18`). Any app with INTERNET can bind that port whenever `adb reverse` does not hold it. It completes PAIRING, seals ACCEPTED and decrypts FILES_INFO(READY, port, token) (`SessionMachine.kt:310`; published by `C/files/FilesController.kt:79-99` whenever the server listens). With the token, DigestAuth grants full DAV read/write on `/sdcard`. This breaks decision 0015 item 3 ("tabletteki başka uygulamalar localhost üzerinden dosyalara erişemez").
3. **Same-`host_id` overwrite → DoS.** The overwrite happens at the first ack even without ACCEPTED. The next PAIRED connection to the real Mac derives with the wrong key, the first host record fails AEAD → `lose(PROTOCOL_ERROR)` (`SessionMachine.kt:211-216`) → retry forever.
4. **Migration on a plaintext ack** (A2 side finding; audit §4.7). A T-096 candidate is promoted on the **plaintext** PAIRED/ACCEPTED first ack (`SessionMachine.kt:463` → `promote` :492-511; posted at `SessionController.kt:677`), before any authenticated host record. AutoUsbPolicy migrates every interval while ACCEPTED and the cable is not reported DISCONNECTED (`AutoTransport.kt:193-201`). A localhost squatter that knows the real `host_id` (clear in every PAIRED/PAIRING ack) pulls a live Wi-Fi session onto itself: DoS (everything after is sealed under `pair_key`). The candidate already never pairs: `candidateKeys.put` throws (`SessionController.kt:154-161`) and a PENDING ack aborts (`SessionMachine.kt:465`).

**Design (decision 0018 option (c)); the implementer may refine names, not semantics**
- **Store.** Trusted record unchanged: `pairkey.<hostIdHex>` = wrap(key, aad = hostId) (no migration of existing keys). New pending record: `pairpend.<hostIdHex>` = wrap(key(32) ‖ sas(6 ASCII digits), aad = hostId ‖ "pending"). `PairKeyStore` gains `getPending/putPending/promote/dropPending/remove`. `promote` is **one** atomic commit: write the trusted record (re-wrapped with aad = hostId) and remove the pending one in a single `SharedPreferences.Editor.commit()`. That needs `remove` and a multi-key commit on `KeyValueStore` (`C/session/Settings.kt:7-10`), and the Android implementation is the anonymous object at `MainActivity.kt:472-480` (this object and the compile-only branch below are the only `MainActivity.kt` changes in this card). The SAS is a secret like the key: wrapped, never logged.
- **Handshake / reader.** `storePairKey` becomes `storePending` at the same point (`SessionController.kt:663-670`), but **only when the connection is user-initiated**. On a non-user-initiated connection a PAIRING ack is aborted right there: nothing is stored, no SAS is surfaced, the connection is closed, records that may follow the ack are never decrypted or processed, and the machine emits `SessionUi.PairingNeedsUser(hostName, rePair)` (`rePair` = a trusted key exists for that `host_id`). In `complete()`, a PAIRED ack for a `host_id` that has a pending record must **never** derive with the pending key (nor silently with an older trusted key): return a distinct outcome so the machine shows the stored code for confirmation (see the orphan criterion) and reconnects after the user decides.
- **`userInitiated`.** `SessionController.start(endpoint, wake, userInitiated = false)` (`SessionController.kt:203`) → `Event.Start(…, userInitiated)`. It holds for the automatic retries of that same start until ACCEPTED, Cancel or Stop. The MainActivity call sites (`connect` at `MainActivity.kt:1850-1857`, called from :1536, :1548, :1807 and :1836, and the wake attempt's direct `controller.start` at :1990) are changed in T-151, not here.
- **Machine.** Track `hostAccepted` and `locallyTrusted` (or a phase `HOST_ACCEPTED_UNTRUSTED`). `inputAllowed` requires both. New events `TrustConfirmed(gen)` and `TrustCancelled(gen)`; controller entry points `confirmTrust()`, `cancelTrust()` and `forgetCurrentHost()` (removes the trusted and the pending record of the `host_id` seen on the current or most recent connection in this process, returns false when none is known; used by T-151's "Bu Mac'i unut" and T-156's recovery text). While accepted-but-untrusted: only PING goes out; the UI stays `AwaitingApproval(needsLocalConfirm = true, code)` and is **never** `Connected` (so MainActivity neither hides the panel, opens input capture nor starts outbound clipboard). Keep PINGs running: the client pings every 500 ms in PENDING/ACCEPTED (`SessionMachine.kt:356-369`) and the host's silence limit is 5 s, so the host tolerates the wait; no host "video must open" watchdog was found (re-checked on the device in T-157).
- **Buffered STREAM_CONFIG.** The host sends STREAM_CONFIG once at ACCEPTED; `onConfig` drops it unless ACCEPTED/STREAMING (`SessionMachine.kt:340-341`). Buffer the latest one and apply it after confirmation; video opens only then.
- **Gates moved to tested code.** `SessionController` has no JVM test today, so the inbound CLIPBOARD gate (:367), the audio gate (:728-758), SETTINGS_OPEN and the reader's user-initiated abort must be decided in the machine or in small pure helpers that the tests drive.
- **Local-confirm timeout (2 min).** It runs while the confirmation prompt is shown in the foreground. A pending record found when the app returns is shown again with its stored code and is not dropped merely because background time passed: the orphan flow (see the code → Home/Parsec → "İzin ver" on the Mac → return; NOTES 2026-09-30 l.253) depends on it, and the Mac keeps its own window for 2 min. Record the exact rule in Handoff so the orchestrator can mirror it in 0018.
- **Migration gate (recommended shape).** On the candidate's plaintext ACCEPTED, send the proof PING **on the candidate** while the Wi-Fi session stays current, and promote only when the candidate's first host record authenticates (the host answers the proof with STREAM_CONFIG then PONG; host `SessionMachine.swift:696-716`). The real host supersedes the old session on that proof (BYE(SUPERSEDED) + close on the old connection), and those may arrive before the candidate's record: while a proved candidate is pending they must not trigger `lose()`. Keep input flowing on the current (Wi-Fi) generation until the promotion itself (then the existing gate switch at `SessionController.kt:372` applies). Do **not** close the input gate during the proof wait: if the candidate is a squatter the real host never supersedes, and an up event refused meanwhile would stay stuck on the Mac. When the real host does supersede, it releases everything held on the old connection before dropping it (PROTOCOL §3, §7), so inputs it discards are harmless. A bad first record or the 3 s candidate deadline (`MIGRATE_TIMEOUT_US`) aborts the candidate with a reason that `AutoUsbPolicy.outcomeOf` maps to HARD_FAIL (`AutoTransport.kt:251-255`, `SOFT_REASONS` :275-278), so AUTO backs off instead of retrying every interval. `MigrationTest.successfulMigrationRetiresThenPromotesThenProvesFirst` (`client-android/app/src/test/kotlin/dev/matebridge/client/session/MigrationTest.kt:57-98`) encodes today's order and is rewritten. An alternative ("tentative promotion with rollback to the retired connection") is allowed if the acceptance criteria hold; say which one in Handoff.
- **Compile-only edits outside the core files.** A new `SessionUi` subtype breaks the exhaustive `when`s in `MainActivity.applyStatusText` (`MainActivity.kt:1893-1909`), `AutoUsbPolicy.stageOf` / `onProbeOpen` (`AutoTransport.kt:243-248`, `:265-269`) and `WakePlanner.reached` (`C/session/Wol.kt:361-365`). Add the minimal mapping only: plain status text; `WAITING_USER` / `IGNORE`; `reached = true`. T-151 owns the real UI. No other change in those three files.
- **Not changed here (residual, documented):** the normal non-candidate PAIRED connection still goes ACCEPTED on the plaintext ack (`SessionMachine.kt:302-317`). Nothing leaks there: everything the tablet sends is sealed under `pair_key`, so a squatter only gets ciphertext and then fails AEAD (T-156 gives that a clear state).
- **Logging.** Replace `pair_key_stored` with events such as `pair_pending_stored`, `pair_trust_confirmed`, `pair_trust_cancelled reason=`, `pairing_needs_user re_pair=`, `migration_proof_wait`. No SAS, key, token, `host_id` or host name in fields. `docs/LOGGING.md` is updated by the orchestrator: list the new lines under *Açık sorular*.
- **PROTOCOL.md (orchestrator, prose only, before start):** §3 step 3 (the client also needs local confirmation before sending anything but PING) and §9 "Eşleşme" bullets 1/3 and "Bağlantı koptuktan sonra onay" (1)/(3). No message, field, fixture or `crypto_vectors.json` change; `gen.py --check` stays green.
- **Serialize with:** T-146 (same file `MainActivity.kt`; chain T-146 → T-150 → T-151 → T-153 → …) and T-156, T-159, T-160, T-197 (same files `SessionMachine.kt` / `SessionController.kt`; chain T-150 → T-156 → T-159 → T-160 → T-197).
- **Size / split suggestion:** if the migration gate does not fit in the same context window, split it into a follow-up card and record that under *Açık sorular*. The trust gate (everything else) must not be split. The migration DoS stays open until the follow-up merges.
- **Review:** security and input-state change: the orchestrator runs `./scripts/codex-review.sh main task/T-150-… --high`.

## Kapsam dışı

- Buttons, prompts, texts and the `userInitiated` call sites in MainActivity, WakeConnect and AutoTransport (T-151).
- Host changes: proof-first PAIRED activation (T-152), orphan-request guard (T-155).
- File-server lifetime (T-153); `KEY_MISMATCH` state (T-156); device acceptance (T-157).
- Any wire, fixture or crypto-vector change.

## Kabul kriterleri

All JVM criteria use a scripted fake host: a test harness that plays the host side with real crypto (as `CryptoVectorsTest` / `SecureChannelTest` do), sending a plaintext PENDING(PAIRING) or PAIRED/ACCEPTED first ack and then sealed records, and drives `ClientHandshake`, `PairKeyStore` and `SessionMachine` (plus the extracted controller decisions).

- [ ] [JVM] **Known host_id, no local confirm.** Trusted key K stored; user-initiated connection; PAIRING ack, then a sealed ACCEPTED: K is unchanged; a pending record holds the new key and code; `inputAllowed == false`; the UI is `AwaitingApproval(needsLocalConfirm = true)` and never `Connected`; only PING goes out (no STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS, FILES_INFO or input). Inbound CLIPBOARD, SETTINGS_OPEN, AUDIO_CONFIG and AUDIO_FRAME are not delivered.
- [ ] [JVM] **Unknown host_id, no local confirm.** Same sequence: no trusted key is created and the session is not ACCEPTED.
- [ ] [JVM] **Localhost WebDAV-token path (A2 §2).** File sharing READY (`FilesInfo(READY, port, token)` set on the machine). A fake host on the USB endpoint `127.0.0.1:47001` completes PAIRING and sends a sealed ACCEPTED: (a) reached through the AUTO probe or USB mode (`userInitiated = false`): the connection aborts at the PAIRING ack, nothing is stored, and **no FILES_INFO is ever queued**; (b) reached through a user-initiated connect: FILES_INFO is not queued until the user confirms locally. The FILES_INFO token never leaves the tablet to an endpoint the user did not confirm.
- [ ] [JVM] **Auto-discovered fake host (A2 §1).** A discovered Wi-Fi endpoint (and, separately, the remembered `lastWifiEndpoint`) answers PAIRING with a new `host_id` and a sealed ACCEPTED in the same write: the connection aborts before storing pending; the following ACCEPTED record is never processed; the result is `SessionUi.PairingNeedsUser(hostName, rePair = false)`; nothing is sent but HELLO. With the **stored Mac's `host_id`** the result is `PairingNeedsUser(…, rePair = true)` and the trusted key is byte-identical afterwards (overwrite/DoS path closed).
- [ ] [JVM] **User-initiated pairing.** A PAIRING ack on a connection opened with `userInitiated = false` (discovery, saved endpoint, USB/AUTO probe, wake connect) aborts before storing pending and yields `PairingNeedsUser(hostName, rePair)`; this state does not retry automatically (each retry would raise a new approval dialog on the Mac). The same ack on `start(…, userInitiated = true)` proceeds to the pending state. Automatic retries of a user-initiated start stay user-initiated until ACCEPTED, Cancel or Stop; a new PAIRING ack on such a retry replaces the pending record with the new key and code (the host also drops its earlier request, host `SessionMachine.swift:683-687`).
- [ ] [JVM] **Both orders.** Local confirm then host ACCEPTED, and host ACCEPTED then local confirm: pending is promoted (trusted = new key, pending removed); the session goes ACCEPTED with the existing action order (PING, STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS, FILES_INFO), `Connected` is emitted only then, and a STREAM_CONFIG that arrived before confirmation is buffered (latest only) and applied after it, opening video.
- [ ] [JVM] **Orphan / Parsec flow (T-043/T-044).** Drop during approval, then: (i) local confirm on return (pending still present), next connection PAIRED → completed with the promoted key; (ii) the automatic reconnect on return gets a PAIRED ack for a `host_id` whose record is still pending → no key is derived from the pending (or an older trusted) key, no AEAD failure and no retry loop occur, the UI shows `AwaitingApproval(needsLocalConfirm = true)` with the **stored** code; after confirm the next connection completes PAIRED.
- [ ] [JVM] **Cancel / timeout / REJECTED.** Each deletes pending; trusted is unchanged. The 2 min local-confirm timeout follows the rule recorded in Handoff (foreground prompt; a pending record found on return is shown, not silently dropped). A PAIRED handshake never uses an unconfirmed pending key.
- [ ] [JVM] **Atomic promotion.** A store whose commit fails yields `KEY_STORE_FAILED`; afterwards either the old state (trusted K, pending P) or the new state (trusted P, no pending) holds, never a mix or a half-written record.
- [ ] [JVM] `forgetCurrentHost()` removes the trusted and the pending record of the last seen `host_id` only (other hosts' records untouched) and returns false when no `host_id` was seen; the next PAIRED ack for that host yields `KEY_MISSING`.
- [ ] [JVM] **Secrets.** SAS, keys and tokens never appear in MbLog output (grep test over a full pairing, confirm, cancel and migration run).
- [ ] [JVM] Old-contract tests are rewritten to assert "not replaced before confirmation": `CryptoVectorsTest.kt:233-245` and `SecureChannelTest.kt:113-119` (`client-android/app/src/test/kotlin/dev/matebridge/client/security/`).
- [ ] [JVM] Migration candidates still never store or pend: a PAIRING ack on a candidate aborts the migration and touches neither record.
- [ ] [JVM] **Migration gate (A2 side finding).** An AUTO-mode USB migration candidate that receives a plaintext PAIRED/ACCEPTED ack is **not** promoted until its first host record decrypts and authenticates. A squatter that knows the real `host_id` and then sends a bad record, or nothing within the candidate deadline, makes the candidate abort; the live Wi-Fi session is untouched (no `lose`, no reconnect, `inputAllowed` stays true on the Wi-Fi generation, video not closed) and the abort reason maps to HARD_FAIL in `AutoUsbPolicy.outcomeOf`. A normal USB migration still promotes: the old video closes once, exactly one new video connection opens after STREAM_CONFIG, no extra `KEYFRAME_REQUEST` beyond today's, and a BYE(SUPERSEDED) or close on the old connection that arrives before the candidate's first record does not end the session. No input from the old generation reaches the new session, and a squatter candidate never causes an input (in particular an up event) on the live session to be refused or dropped.
- [ ] [JVM] Existing session, migration, wake and AUTO tests pass, rewritten only where they encode the old contract (list them in Handoff).
- [ ] The orchestrator ran `./scripts/codex-review.sh` with `--high` and its findings are resolved or recorded.
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
