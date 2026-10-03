---
id: T-156
title: Show "anahtar uyuşmuyor" after repeated PAIRED auth failures
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-151]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionUi.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-156-client-key-mismatch-state.md
---

## Amaç

When the tablet's pair key no longer matches the Mac's, every PAIRED reconnect fails at the first host record and the tablet shows "protokol hatası, yeniden bağlanılıyor" forever. The user gets no hint that the fix is to forget the pairing and pair again. After this card, three consecutive authentication failures on PAIRED connections end in a terminal "Mac anahtarı uyuşmuyor" state that points to "Bu Mac'i unut" on the tablet and "Onaylı cihazları unut" on the Mac, while a single failure still retries as today.

Source: external architecture review 2026-10-03 (H01, DoS residue); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-7, additional issue A3, H01 attack point 4).
Decision 0018 must be accepted by the user before work starts (this card completes its recovery path).

## Bağlam

`C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`. Lines are at HEAD a30c769; T-150 lands first.

- **Evidence:**
  - `C/session/SessionMachine.kt:211-216`: `Event.ProtocolError` on the current connection → `lose(out, nowUs, PROTOCOL_ERROR)` → `WAIT_RETRY` with backoff 1 s → 5 s max (:404-410, :516-517). No limit, no distinct cause.
  - The reader posts `Event.ProtocolError(gen)` for any `ProtocolException` (`C/session/SessionController.kt:681-684`); the event carries no kind. A failed AEAD tag is `ProtocolException.Kind.AUTH_FAILED` (`C/security/Records.kt:204`; also :190, :281 for short records). Other kinds (OVERSIZE, decoding errors) are not key problems.
  - `SessionUi.Cause` (`C/session/SessionUi.kt:24`) has no mismatch cause. `MainActivity.causeText` (`C/MainActivity.kt:2087-2098`) is an exhaustive `when` over `Cause`, and the `Failed` status text is chosen at `:1903-1908`; adding a cause therefore needs those two places (hence `MainActivity.kt` in `files:`; nothing else in it changes).
- **After T-150, realistic causes:** the Mac lost its Keychain item or its host identity was replaced, or a squatter that knows the real `host_id` answers PAIRED and sends garbage (it cannot seal valid records). The latter means the message must not push the user to forget the pairing blindly.
- **Rules:**
  - Count only an `AUTH_FAILED` on the **first** host record of a **PAIRED** connection (nothing authenticated yet on it). Any authenticated record, an ACCEPTED session, a Stop or a user start resets the counter. PAIRING connections and failures after a record authenticated keep today's behaviour.
  - Do not count T-150's "PAIRED ack while a pending record exists" path; it never derives a key, so it must never reach this counter (test it).
  - 3 consecutive → `Failed(KEY_MISMATCH)`: terminal, no automatic retry; AUTO sees `FAILED` (`AutoTransport.kt:246`) and does nothing.
  - Text (Turkish, `strings.xml`): "Bu Mac'in anahtarı uyuşmuyor. Önce Mac'in açık ve doğru Mac olduğundan emin ol; sonra tablette 'Bu Mac'i unut' ve Mac'te 'Onaylı cihazları unut' deyip yeniden eşleş."
  - Log `session_failed cause=KEY_MISMATCH` (existing line, `SessionController.kt:476`); no key material.
- **Serialize with:** T-159 and T-160 (same files `SessionMachine.kt` / `SessionController.kt`; chain T-150 → T-156 → T-159 → T-160 → T-197) and T-153 (same file `MainActivity.kt`; both depend on T-151).
- No wire change; `docs/PROTOCOL.md` is not affected. A `docs/LOGGING.md` note for the new cause goes under *Açık sorular*.

## Kapsam dışı

- Automatic forgetting or re-pairing; host changes; the trust logic itself (T-150) and the forget action (T-151).

## Kabul kriterleri

- [ ] [JVM] Three consecutive first-record `AUTH_FAILED` errors on PAIRED connections → `Failed(KEY_MISMATCH)`; no further `OpenControl` until a user start.
- [ ] [JVM] A single failure (and two) still retries with today's backoff; a successful authenticated record in between resets the count.
- [ ] [JVM] Non-auth protocol errors, failures on PAIRING connections, failures after a record authenticated, and T-150's pending-confirm path never count toward the limit.
- [ ] The `KEY_MISMATCH` text points to "Bu Mac'i unut" (tablet) and "Onaylı cihazları unut" (Mac) and comes from `strings.xml`.
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
