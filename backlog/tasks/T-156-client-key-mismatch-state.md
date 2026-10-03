---
id: T-156
title: Show "anahtar uyuşmuyor" after repeated PAIRED auth failures
status: in-progress
phase: 6
owner: android-client-dev
depends_on: [T-151]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionUi.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/AutoTransport.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-156-client-key-mismatch-state.md
---

## Amaç

When the tablet's pair key no longer matches the Mac's, every PAIRED reconnect fails before any host record authenticates (today as `AUTH_FAILED` on the first record; with a T-152 host as a close without BYE right after the proof PING), and the tablet shows "protokol hatası" / "bağlantı koptu, yeniden bağlanılıyor" forever. The user gets no hint that the fix is to forget the pairing and pair again. After this card, three consecutive authentication failures on PAIRED connections end in a terminal "Mac anahtarı uyuşmuyor" state that points to "Bu Mac'i unut" on the tablet and "Onaylı cihazları unut" on the Mac, while a single failure still retries as today.

Source: external architecture review 2026-10-03 (H01, DoS residue); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-7, additional issue A3, H01 attack point 4).
Decision 0018 must be accepted by the user before work starts (this card completes its recovery path).

## Bağlam

`C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`. Lines are at HEAD a30c769; T-150 lands first.

- **Evidence:**
  - `C/session/SessionMachine.kt:211-216`: `Event.ProtocolError` on the current connection → `lose(out, nowUs, PROTOCOL_ERROR)` → `WAIT_RETRY` with backoff 1 s → 5 s max (:404-410, :516-517). No limit, no distinct cause.
  - The reader posts `Event.ProtocolError(gen)` for any `ProtocolException` (`C/session/SessionController.kt:681-684`); the event carries no kind. A failed AEAD tag is `ProtocolException.Kind.AUTH_FAILED` (`C/security/Records.kt:204`; also :190, :281 for short records). Other kinds (OVERSIZE, decoding errors) are not key problems.
  - **After T-152 the host sends no record before the proof** (`start()` → STREAM_CONFIG only inside `prove()`). On a wrong key it closes **without BYE** at `recordAuthFailed` (host `SessionMachine.swift:275-277`). The client then sees EOF → `ControlClosed` → `lose(LOST)` (`SessionMachine.kt:198-208`), never `AUTH_FAILED`. T-152 can merge before this card, so counting only `AUTH_FAILED` would never fire (QA-1 blocker).
  - `SessionUi.Cause` (`C/session/SessionUi.kt:24`) has no mismatch cause. `MainActivity.causeText` (`C/MainActivity.kt:2087-2098`) is an exhaustive `when` over `Cause`, and the `Failed` status text is chosen at `:1903-1908`; adding a cause therefore needs those two places (hence `MainActivity.kt` in `files:`; nothing else in it changes).
- **After T-150, realistic causes:** the Mac lost its Keychain item or its host identity was replaced, or a squatter that knows the real `host_id` answers PAIRED and sends garbage (it cannot seal valid records). The latter means the message must not push the user to forget the pairing blindly.
- **Rules:**
  - Count a **PAIRED** connection that ends before any host record authenticated on it, i.e. either (a) `AUTH_FAILED` on the first host record (host without T-152), or (b) the control connection closing (EOF or I/O error; a BYE would itself be an authenticated record) **after the proof PING went out and before any authenticated host record** (host with T-152). A connection that closes before the proof PING was sent (connect failure, plaintext BUSY/REJECTED, close during the handshake) does not count.
  - Any authenticated record, an ACCEPTED session with an authenticated record, a Stop or a user start resets the counter. PAIRING connections and failures after a record authenticated keep today's behaviour.
  - The counter is **per endpoint** (a USB squatter must not poison the Wi-Fi path).
  - Do not count T-150's "PAIRED ack while a pending record exists" path; it never derives a key, so it must never reach this counter (test it).
  - 3 consecutive → `Failed(KEY_MISMATCH)`: terminal, no automatic retry. Exception in AUTO on the USB endpoint: `KEY_MISMATCH` there falls back to Wi-Fi (`AutoUsbPolicy.shouldFallBack`) instead of staying terminal, because a localhost squatter that knows `host_id` (answers PAIRED, then closes) would otherwise park AUTO on a text that tells the user to forget the real Mac. On Wi-Fi (or in USB/WIFI mode) AUTO sees `FAILED` (`AutoTransport.kt:246`) and does nothing.
  - Text (Turkish, `strings.xml`): "Bu Mac'in anahtarı uyuşmuyor. Önce Mac'in açık ve doğru Mac olduğundan emin ol; sonra tablette 'Bu Mac'i unut' ve Mac'te 'Onaylı cihazları unut' deyip yeniden eşleş."
  - Log `session_failed cause=KEY_MISMATCH` (existing line, `SessionController.kt:476`); no key material.
- **Serialize with:** T-205, T-160, T-183 and T-197 (same files `SessionMachine.kt` / `SessionController.kt`; chain T-150 → T-205 → T-156 → T-160 → T-197; T-159 no longer touches the session files), T-150 and T-151 (same file `AutoTransport.kt`; T-151 is depends_on), T-151 (same files `SessionUi.kt`, `strings.xml`), T-159 (`strings.xml`) and T-153 (same file `MainActivity.kt`; both depend on T-151).
- No wire change; `docs/PROTOCOL.md` is not affected. A `docs/LOGGING.md` note for the new cause goes under *Açık sorular*.

## Kapsam dışı

- Automatic forgetting or re-pairing; host changes; the trust logic itself (T-150) and the forget action (T-151).

## Kabul kriterleri

- [ ] [JVM] (a) Three consecutive first-record `AUTH_FAILED` errors on PAIRED connections → `Failed(KEY_MISMATCH)`; no further `OpenControl` until a user start.
- [ ] [JVM] (b) Three consecutive PAIRED connections that close without BYE after the proof PING and before any authenticated host record (T-152 host) → `Failed(KEY_MISMATCH)`; a mix of (a) and (b) also counts.
- [ ] [JVM] A single failure (and two) still retries with today's backoff; a successful authenticated record in between resets the count.
- [ ] [JVM] Non-auth protocol errors, closes before the proof PING went out, failures on PAIRING connections, failures after a record authenticated, and T-150's pending-confirm path never count toward the limit.
- [ ] [JVM] The counter is per endpoint; in AUTO, `KEY_MISMATCH` on the USB endpoint makes `shouldFallBack` true (fallback to Wi-Fi), while on Wi-Fi it stays terminal.
- [ ] [build] The `KEY_MISMATCH` text points to "Bu Mac'i unut" (tablet) and "Onaylı cihazları unut" (Mac) and comes from `strings.xml`.
- [ ] [device] Covered by T-157 step 10.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `SessionMachine.kt`: `Event.ProtocolError` gets `authFailed: Boolean = false`. A per-endpoint counter
   (`Map<Endpoint, Int>`) counts a connection that is PAIRED (`!pairingSession`), in `ACCEPTED` (= the PAIRED ack came,
   the proof PING went out) with no authenticated host record yet (`!sealedSeen`) and no candidate, when it ends with
   (a) `ProtocolError(authFailed = true)` or (b) `ControlClosed` (not a connect failure). Below the limit it retries as
   today (`lose`, same cause/backoff); at 3 it ends in `Failed(KEY_MISMATCH)` (close, no BYE, no retry timer).
   The first authenticated record (where `sealedSeen` flips) resets the current endpoint's count; Stop, a user start and
   ForgetHost clear all counts. An automatic start to an endpoint at the limit opens nothing and shows
   `Failed(KEY_MISMATCH)` again (like T-150's cancel latch), so "no OpenControl until a user start" holds. T-150's
   `PairedWithPending` path and handshake errors (still `AWAIT_ACK`) never reach the counter. Log line
   `paired_auth_fail count=N how=auth_failed|closed` (no key material).
2. `SessionController.kt`: one line, the reader passes `e.kind == AUTH_FAILED` into `ProtocolError`.
3. `SessionUi.kt`: `Cause.KEY_MISMATCH`.
4. `AutoTransport.kt`: `shouldFallBack` also true for `Failed(KEY_MISMATCH)` on USB in AUTO.
5. `MainActivity.kt`: `causeText` branch + `applyStatusText` `Failed` text from `strings.xml` (`key_mismatch`).
6. Tests: new `KeyMismatchTest.kt` (a, b, mix, resets, non-counting cases, per endpoint, latch, PairedWithPending via the
   real `FirstAck`/trust fixture path if practical, AUTO fallback); existing tests must keep passing.

Risk: existing tests that lose a never-authenticated PAIRED session 3× would now fail terminally; check and adapt only
if they test something unrelated.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
