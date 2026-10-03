# QA-1: cards T-145 … T-157 (read-only, HEAD 84c0c4c; code facts at a30c769-equivalent sources)

Totals: **1 blocker, 15 should-fix, 17 nit.**

Trust-design verdict, short: the gates in T-150 cover every inbound/outbound path I could find (input via `trySend`/`trySendInput`, outbound clipboard via `render(Connected)`, inbound CLIPBOARD `SessionController.kt:367`, AUDIO reader path `:728-758`, SETTINGS_OPEN `SessionMachine.kt:283`, FILES_INFO/STREAM_PREFS/DISPLAY_RATE/AUDIO_PREFS in `onAck`/`Set*`, video only after STREAM_CONFIG). There is no message type in `SessionListener` (`SessionController.kt:59-99`) that the cards leave ungated. The holes are in state transitions:
- the orphan flow when the user returns early (T-150 #1);
- a stale pending record (T-150 #2);
- trust revocation on a live session, which breaks the "inputAllowed false ⇒ host holds nothing" invariant and so can strand an up event (T-150 #3);
- cancel after the Mac approved (T-150 #4);
- a T-152 × T-156 contradiction (blocker).

The migration-gate text already handles up events correctly.

---

## T-145: 1 nit
1. **nit:** Acceptance item 2 ("`bundle-host.sh` writes `MBGitCommit` … `plutil -lint`") has no marker, and it needs the Mac. **Fix:** prefix it with `[device]`.

## T-146: 2 nits
1. **nit:** The `versionCode` fallback of 1 (no `.git`, or a shallow CI checkout) is lower than a count-based APK that is already installed. `adb install -r` then fails with INSTALL_FAILED_VERSION_DOWNGRADE, and the obvious workaround (uninstall) deletes `matebridge_pairkeys`, i.e. the pairing. **Fix:** add to *Plan hints*: "Fallback builds must never be installed over a count-based APK; if needed use `adb install -r -d`. Never uninstall (it deletes the pair keys)."
2. **nit:** Acceptance items 2–3 (`assembleDebug` without `.git`; `versionCode` follows the count) have no marker. **Fix:** mark them `[build]` (or `[doc]` with the output quoted in Handoff).

## T-147: 1 nit
1. **nit:** Step 5 says "AUTO on Wi-Fi … switch Wi-Fi off with the cable plugged". With the cable plugged and the Mac's USB mode on, AUTO has already migrated to USB (`AutoTransport.kt:193-201`), so the scenario tests nothing. **Fix:** "start on Wi-Fi with the cable unplugged, plug it in, then switch Wi-Fi off; record migration time and the fallback on unplug."

## T-148: OK

## T-149: OK

## T-150: 7 should-fix, 2 nits
1. **should-fix (high): the orphan/Parsec flow breaks when the user returns to MateBridge before clicking "İzin ver".**
   - Evidence:
     - `onStop` → `controller.stop()` (`MainActivity.kt:1781`).
     - `onStart` → `applyTransport()` (`:1501`) reconnects automatically, which after T-150/T-151 is `userInitiated = false`.
     - The host has not approved yet, so it answers PAIRING. Any new PAIRING request cancels the open orphan window and replaces its key (`SessionMachine.swift:683-687`).
     - The tablet aborts that connection without storing anything. Its pending (or already locally confirmed) key A no longer matches the key B behind the Mac's new orphan dialog.
     - If the user confirmed A before leaving (the new Parsec hint invites this) and then approves B through Parsec, the Mac stores B and the tablet holds A. Result: an endless mismatch, and T-156 KEY_MISMATCH at best.
   - Parsec runs on the same tablet (NOTES l.105, l.255), so switching back to read the code is the natural move. Before T-150 the re-roll stayed consistent, because the tablet stored B. Criterion (ii) covers only "Mac already approved → PAIRED".
   - **Fix:** add a criterion:

     > [JVM] Return before the Mac approved: while a pending record (or a key confirmed less than 2 min ago) from a user-initiated pairing exists, the foreground return does not open a connection that could raise a new PAIRING on the Mac. It shows the stored code with "Kodlar aynı — Güven / İptal" (and "Yeniden eşleş"), and connects only after a user action. That connection counts as user-initiated, so a new PAIRING replaces pending and shows the new code on both sides.

   - Also add a T-157 step (see T-157 #2).
2. **should-fix: "PAIRED ack + pending ⇒ show the stored code, never use the trusted key" lets a stale or attacker-made pending record hijack the silent reconnect to the real Mac.**
   - Scenario:
     - A LAN impostor uses the real `host_id` (clear in every ack).
     - The user taps "Eşleş" on `PairingNeedsUser(rePair = true)`, sees no dialog on the Mac, and leaves the app without "İptal".
     - The pending record survives indefinitely, because the timeout runs only in the foreground.
     - The next normal PAIRED reconnect to the **real** Mac is blocked: the tablet presents the attacker's code with "Kodlar aynı — Güven".
     - Confirming installs the attacker's key. The real Mac then fails, and the attacker gets a silent PAIRED session later (input capture).
   - **Fix (Design → Local-confirm timeout):** "A pending record older than N minutes of wall-clock time (default 10, i.e. well past the Mac's 2-min orphan window) is dropped when read and never shown. PAIRED + stale pending derives with the trusted key as today. Add [JVM]: stale pending + PAIRED ack → silent PAIRED with the trusted key, pending deleted." Record N in Handoff for 0018.
3. **should-fix: trust revocation on a live session is unspecified, and that is where an up event can be lost.**
   - `forgetCurrentHost()` (and T-151's "Bu Mac'i unut", reachable in-stream from the settings panel, `SettingsCatalog.sections(h, inStream)`) has no defined effect on the open session.
   - If an implementation clears `locallyTrusted` on the live connection, `inputAllowed` goes false while the host still holds keys or buttons:
     - `trySend` refuses the up or the RELEASE_ALL;
     - `dropConnection()` is a no-op when `!inputAllowed` (`SessionController.kt:302-305`, whose comment says "the host holds nothing then").
     - Result: a stuck key or pen on the Mac. This violates the AGENTS.md hard rule.
   - **Fix:** add to Design → Machine:

     > `locallyTrusted` never goes true→false on an open connection. `forgetCurrentHost()` on a live session first ends it like Stop (BYE graceful + close; the host releases all input, PROTOCOL §7), then removes the records. [JVM]: a key held (down sent) + `forgetCurrentHost()` → BYE and CloseControl are emitted, and no state exists where `inputAllowed == false` while the control connection that carried the down is still open.

4. **should-fix: Cancel or timeout after the host's ACCEPTED, and REJECTED after a local confirm, are inconsistent.**
   - After "İzin ver" the Mac has persisted P. Tablet "İptal" or the 2-min timeout drops P and keeps K, so every later PAIRED fails (mismatch loop, see T-156).
   - Separately, the criterion "Cancel / timeout / REJECTED … trusted is unchanged" contradicts "confirm promotes at once": a REJECTED that arrives after a local confirm finds trusted == P already.
   - **Fix:**
     - Criterion text: "REJECTED before local confirm deletes pending; after local confirm the promoted key stays (harmless: the Mac answers PAIRING next time)."
     - New [JVM]: "Cancel or timeout while host-accepted-untrusted → BYE + close; pending deleted; UI `Failed(…)` with text 'Mac bu tableti onayladı ama sen iptal ettin — Mac'te Onaylı cihazları unut'."
     - Or state explicitly that this path ends in T-156's KEY_MISMATCH.
5. **should-fix: KeyValueStore changes break files outside `files:`.**
   - Adding abstract `remove` / multi-key commit to `KeyValueStore` (`Settings.kt:7-10`) breaks:
     - the test fakes in `CT/input/InputSupportTest.kt:16`, `CT/stream/GameModeTest.kt:17` and `CT/stream/StreamModeTest.kt:11` (outside `files:`);
     - the settings adapter `MainActivity.kt:455` (the card allows only `:472-480`).
   - T-191 already warns about this (`T-191 … :44`).
   - **Fix:** add to Design → Store: "New `KeyValueStore` methods get default bodies (e.g. `remove` throws `UnsupportedOperationException`), or put them on a separate `AtomicKeyValueStore` that only `EncryptedPairKeyStore` requires. No other implementer or fake changes."
6. **should-fix: size.**
   - The card has: a store with atomic promotion, a handshake outcome, two machine flags, a buffered config, three moved gates, user-initiated plumbing, forget, a timeout, the migration-gate rewrite (including `MigrationTest`), compile-only edits in three files, and ~15 JVM criteria. That is beyond one Sonnet context.
   - The card already designates the migration gate as splittable.
   - **Fix:** pre-split now into a follow-up card (e.g. "T-150b client-migration-proof-gate", depends_on [T-150], same files subset, serialize-with T-156), rather than leaving it to the implementer. T-157 step 7 then depends on it.
7. **should-fix: nobody owns the 2-min timer.** The timeout must run only "while the prompt is shown in the foreground", but neither T-150 nor T-151 says who knows that or who runs the timer. T-151 has no timeout criterion at all.
   - **Fix (T-150 Design):** "Machine event `ConfirmPromptVisible(visible: Boolean)` posted by the UI. The machine runs the 2-min deadline on Tick only while it is visible." In T-151, add a [JVM] criterion: "prompt shown/hidden posts `ConfirmPromptVisible`; background → not visible".
8. **nit:** `forgetCurrentHost()` uses "the `host_id` seen on the current or most recent connection", which includes attacker-chosen ids from aborted PAIRING answers. **Fix:** "the `host_id` of the last PAIRED ack or locally trusted session."
9. **nit:** Residual exposure is not recorded anywhere. HELLO (cleartext `device_id`, device name) still goes to every discovered, remembered or loopback endpoint, and that `device_id` is what feeds A1 (T-152) and the Mac-dialog pop. **Fix:** in *Not changed here*, add "HELLO (device_id, device name) is still sent to any endpoint before the PAIRING abort; T-152 removes its host-side effect" so 0018 can list it.

## T-151: 2 should-fix, 2 nits
1. **should-fix: one impostor service causes a persistent auto-connect DoS plus a social-engineering prompt.**
   - `PairingNeedsUser` never retries (T-150). `WakeConnect.onDiscovered` connects only when `current == null || disconnected` (`WakeConnect.kt:127-134`). So the first answering Bonjour impostor parks the tablet on "Kendini 'Mac mini' olarak tanıtan … Eşleş", and the real Mac, discovered later, is ignored.
   - In AUTO, a localhost squatter on 47001 does the same on every `onStart` probe. `PairingNeedsUser` maps to WAITING_USER (no probe, no migrate), and `shouldFallBack` fires only on `Disconnected` (`AutoTransport.kt:272-273`), so the tablet never falls back to Wi-Fi.
   - **Fix:** add a [JVM] criterion:

     > While `PairingNeedsUser` from a non-user-initiated connection is shown, discovery keeps running. Another service that answers PAIRED with a trusted key connects silently and replaces the prompt. In AUTO, `PairingNeedsUser` on the USB endpoint falls back to Wi-Fi like `Disconnected` (prompt kept as a non-blocking banner).

2. **should-fix:** "Bu Mac'i unut" can be tapped in-stream (the settings panel is available while streaming), and T-157 has no step for it although this card says "[device] covered by T-157".
   - **Fix:** add a [JVM] criterion: "forget while Connected ends the session first (T-150 #3), then removes records; UI goes to the forget-done text."
   - Add a T-157 step (see T-157 #1).
3. **nit:** In USB mode the USB hint replaces the prompt text. `hostReached` is set only for `AwaitingApproval|Connected|Failed` (`MainActivity.kt:1876`), so `showUsbHint` (`:1910-1912`) overwrites the `PairingNeedsUser` text. **Fix:** "Include `PairingNeedsUser` in the `hostReached` condition."
4. **nit:** Several acceptance items are unmarked: the key-changed warning, the stored code on return, the Parsec text, and the log grep. UI log events in `MainActivity` are not JVM-testable. **Fix:** mark them `[JVM]` with the text/state mapping in a pure helper (e.g. `TrustUiText`), or `[device] (T-157)`. The grep covers the pure helper's log fields.

## T-152: 2 nits
1. **nit:** `.proving` is not a slot owner (`SessionMachine.swift:575-580`). During a non-takeover proof (~1 RTT), a PAIRING HELLO from another device takes the slot as pending, and the real tablet's proof is then answered BUSY (`prove()` :698-708). The window is tiny and the exposure is pre-existing (no-session gaps), but it should be documented. **Fix:** add [XCTest] "PAIRING HELLO from device B while device A's non-takeover PAIRED is proving: outcome documented (A gets BUSY at proof; B pending)".
2. **nit:** The *Interaction* section omits T-156. **Fix:** add "After this card a wrong client key is never seen as AUTH_FAILED on a host record: the host closes without BYE at the bad proof (`recordAuthFailed`, :275-277). T-156 must count that (see T-156 #1)."

## T-153: 1 should-fix, 1 nit
1. **should-fix:** The [JVM] criterion "OFF is published before the stop, and the next start publishes a different token" is not JVM-testable as scoped. `FilesController` depends on `android.os.Build`, `Environment` and `Process` (`FilesController.kt:37`, `:84`), and there is no Robolectric (`build.gradle.kts:37`, junit only).
   - **Fix:** either add `client-android/app/src/main/kotlin/dev/matebridge/client/files/FilesLifecycle.kt` (new, pure: decides start/stop and the publish order over an injected server factory) to `files:`, or reword the criterion to "[JVM] `FilesSwitch` transition table; [device] OFF before stop and a new token on restart (`server state=off` then a new `state=on`)".
2. **nit:** `lastUi is SessionUi.Connected` is emitted for a PAIRED connection at the **plaintext** ack, before any host record authenticated (`SessionMachine.kt:302-317`; T-150 keeps that residual). So the listener (with a fresh token) starts for an unauthenticated PAIRED peer. **Fix:** "Trusted signal = first STREAM_CONFIG applied on the current session (after T-152 the host sends it only after the proof), not `Connected`."

## T-154: 1 nit
1. **nit:** The first three acceptance items have no marker. **Fix:** mark them `[build]` (manifest/xml/aapt2 output quoted in Handoff).

## T-155: 2 should-fix, 1 nit
1. **should-fix:** Adding `replacedPrevious` to `.requestApproval` changes the case arity. `host-mac/Tests/MateBridgeCoreTests/Crypto/SessionCryptoTests.swift:181` matches `.requestApproval(_, _, _, let c)` and stops compiling, and it is outside `files:`. **Fix:** add that file to `files:`, or carry the flag in a separate action (e.g. `.approvalReplacedPrevious(id, fingerprint:)`) so existing patterns stay valid.
2. **should-fix:** The [device] step "Two-tablet or scripted HELLO test" is not executable. There is one tablet, and there is no scripted-HELLO tool in `tools/` or `scripts/`. T-157 depends_on T-155 but has no step for it. **Fix:** "[device] (T-157 step 9): with an orphan window open from the tablet, launch the APK on a second Android device (phone, sideloaded) → the panel shows 'FARKLI bir cihaz' + fingerprint. If no second device: 'not run', XCTest is the evidence."
3. **nit:** Same-device replacement stays silent. After T-150 this is exactly the T-150 #1 trap: the tablet's aborted automatic reconnect re-rolls the Mac's code while the tablet still shows the old one. **Fix:** "Same `device_id` replacement shows a neutral notice 'Kod değişti — tabletteki kodla yeniden karşılaştır'."

## T-156: 1 blocker, 2 nits
1. **blocker: after T-152 the counter never fires.**
   - The rule counts only "`AUTH_FAILED` on the **first** host record of a PAIRED connection".
   - After T-152 the host sends **no** record before the client's proof (`start()` → STREAM_CONFIG only inside `prove()`). On a wrong key the host closes **without BYE** at `recordAuthFailed` (`SessionMachine.swift:275-277`).
   - The client therefore gets EOF → `ControlClosed` → `lose(LOST)`, never AUTH_FAILED. The card's evidence ("today `lose(PROTOCOL_ERROR)`") is true only before T-152, and T-152 is ordered first (manifest chain T-152 → …; it can start at once).
   - **Fix (Rules + criteria):**

     > Count a PAIRED connection that ends before any host record authenticated, i.e. (a) `AUTH_FAILED` on the first host record (host without T-152), or (b) the control connection closing (EOF/IO error, no BYE) after the proof PING went out and before any authenticated host record (host with T-152). [JVM] tests for both (a) and (b). Context: add T-152 as the reason.

2. **nit:** In AUTO, a localhost squatter that knows `host_id` (answers PAIRED, then closes) drives the USB attempt to a terminal KEY_MISMATCH: there is no Wi-Fi fallback (Stage FAILED, `AutoTransport.kt:246`), and the text suggests forgetting the real Mac. **Fix:** "Counter is per endpoint; in AUTO a KEY_MISMATCH on the USB endpoint falls back to Wi-Fi instead of terminal" (or record this as accepted residual).
3. **nit:** No device evidence is planned, and T-157 does not depend on this card (see T-157 #1).

## T-157: 3 should-fix, 2 nits
1. **should-fix: coverage does not match the stated D2 gate.**
   - *Amaç* says "D2 cards (T-150 … T-156) are set to `done` only after this run passes", but depends_on lacks T-154 and T-156.
   - No step covers T-156 (KEY_MISMATCH), T-155 (replaced request), or T-151's "Bu Mac'i unut", although T-151 and T-155 point here.
   - **Fix:**
     - depends_on → `[T-150, T-151, T-152, T-153, T-155, T-156]`, plus the T-150 migration follow-up if it is split.
     - Amaç: "T-154 is not device-verifiable and is closed on merge".
     - Add steps:
       - 9: "Bu Mac'i unut" on the tablet (2-step), in-stream and idle. Expect: the session ends cleanly (no stuck key), the next connect shows KEY_MISSING text until the Mac forgets, then "Eşleş".
       - 10: KEY_MISMATCH. Produce it via step 2's "İzin ver without tablet confirm → İptal" (Mac holds P, tablet K). Expect three silent retries, then "Bu Mac'in anahtarı uyuşmuyor".
       - 11: T-155 second-device orphan replacement (or "not run").
2. **should-fix:** Step 4 lacks the early-return variant (T-150 #1). **Fix:** add "4b. 'Eşleş' → see code → switch to Parsec → switch **back to MateBridge before** clicking 'İzin ver' → back to Parsec, 'İzin ver' → return. Expect: the Mac's code never changes from what the tablet shows; final state silent PAIRED with video."
3. **should-fix: step 5 is non-deterministic.** After "disconnect" (`userDisconnected` blocks discovery, `MainActivity.kt:1803-1809`) and "Bağlan", the first resolved service wins, and the real Mac also advertises. **Fix:** "Quit MateBridge in the primary user's session (or set the real host to USB-only if T-189 merged) so only the second identity advertises; then 'Bağlan'."
4. **nit:** Step 2's last sub-step ("İzin ver" without tablet confirm) does not say how it ends. The Mac has then stored a key the tablet does not trust. **Fix:** "End: tap 'İptal' (or wait 2 min). Expected end state per T-150 #4. Step 3 starts again from 'Onaylı cihazları unut'."
5. **nit:** "`input_session_end` counts 0" is vague. **Fix:** "`input_session_end messages=0 events=0` (or no `input_session_end` line at all)".

---

### Cross-card / manifest consistency (nits, orchestrator)
These are counted under the cards above, not separately:
- The manifest §2 serialize chains were not updated for card changes:
  - `C/MainActivity.kt` should include T-150 (T-146 → T-150 → T-151 → T-153 …), and T-159's text also omits T-150.
  - `HH/Session/SessionServer.swift` and `HA/main.swift` should include T-155, as T-155's own text says.
- The 0018 "Sonuçlar" text should pick up the residuals and rules decided in T-150 #2/#4/#9.
