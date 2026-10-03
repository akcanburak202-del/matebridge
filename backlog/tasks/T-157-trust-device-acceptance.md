---
id: T-157
title: Run the trust-transition device acceptance (X1)
status: todo
phase: 6
owner: orchestrator
depends_on: [T-150, T-151, T-152, T-153, T-154, T-155, T-156, T-205]
decisions: [0018]
files:
  - docs/NOTES.md
  - backlog/tasks/T-157-trust-device-acceptance.md
---

## Amaç

The D2 cards change who the tablet trusts and when, and most of it is proven only by JVM and XCTest scripts. This card is the device evidence that the trust boundary holds on the real Mac mini and MatePad: a forgotten or fake Mac never gets input, clipboard or the file token without the user's pick and code confirmation, the Parsec/orphan flow still works, AUTO USB↔Wi-Fi migration still works, and a normal reconnect still shows video. It is the merge gate for D2: the D2 cards (T-150 … T-156 and T-205) are set to `done` only after this run passes, and a failed step reopens the responsible card. T-154 (data-extraction rules) is not device-verifiable and is closed on merge; it is in depends_on only so the run uses the final D2 APK. The orchestrator runs the procedure; the user performs the taps and clicks.

Source: external architecture review 2026-10-03 (X1, H01, D2); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-4, X1 corrections) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§1–3).
Decision 0018 must be accepted by the user before work starts.
Gated: start only after T-150, T-151, T-152, T-153, T-154, T-155, T-156 and T-205 are merged and one APK plus one host bundle from that `main` are installed (T-150 and T-151 back-to-back; no APK between them).

## Bağlam

- **Setup and logs.** One device test at a time (CLAUDE.md). Record the `app_start` lines (T-145/T-146, if merged) or the commit SHAs of the installed APK and host bundle. Client log: `adb logcat -s 'MB/*'`; host log: `~/Library/Logs/MateBridge/host.log`. The exact client event names come from T-150/T-151 Handoff (e.g. `pair_pending_stored`, `pair_trust_confirmed`, `pair_trust_cancelled`, `pairing_needs_user`); `pair_key_stored` must not appear any more.
- **Second host identity (steps 5 and 6).** There is no host knob for a separate identity. Use a second macOS user account running its own `MateBridge.app` (own Keychain and defaults → own `host_id`), or a second Mac. On the same Mac the second instance finds 47001/47002 busy and takes system ports (PROTOCOL §3.1); read them from its `listening` line or `dns-sd -B _matebridge._tcp` / `lsof -iTCP -sTCP:LISTEN`. Do not approve anything on it.
- **Localhost squatter (step 6).** Turn "USB modu" off in the real host's menu so it stops re-adding `adb reverse`, run `adb reverse --remove tcp:47001`, then `adb reverse tcp:47001 tcp:<second instance control port>`. From the tablet this is wire-identical to a tablet app squatting `127.0.0.1:47001` (A2 §2), with no extra tooling. Afterwards restore with `adb reverse --remove-all` and "USB modu" back on.
- **Procedure** (for each step record: what the tablet showed, what the Mac showed, the relevant log events, pass/fail):
  1. **Paired baseline.** Kill and relaunch the tablet app. Expect a silent PAIRED reconnect (`handshake mode=paired` in `host.log`), no code screen, video and input working.
  2. **Mac forgets the tablet (same-`host_id` PAIRING).** Mac menu "Onaylı cihazları unut". Expect the tablet's automatic reconnect to show "Mac yeniden eşleşmek istiyor — Eşleş" (not automatic pairing); the Mac may flash an approval window (orphan, 2 min; known T-151 risk). Tap "Eşleş" → code screen with the key-changed warning. Tap "İptal": pending dropped, trusted key kept, nothing injected on the Mac, the tablet shows the `PAIR_CANCELLED` text and does not reconnect on its own. Then tap "Bağlan" and, on the pairing prompt, "Eşleş" again, and on the Mac click "İzin ver" **without** confirming on the tablet: the tablet stays on the code screen, no input, clipboard or FILES_INFO reaches the Mac (`input_session_end messages=0 events=0`, or no `input_session_end` line at all; no `files … info state=ready`). **End:** tap "İptal" (or wait 2 min with the prompt visible). Expect BYE + close, terminal `PAIR_CANCELLED` text telling the user to use "Onaylı cihazları unut" on the Mac (T-150 Cancel rule). The Mac now holds a key the tablet does not trust: run step 10 now, from this state. Step 3 then starts again from "Onaylı cihazları unut".
  3. **Real re-pair.** Repeat step 2 but confirm on both sides ("Kodlar aynı — Güven" + "İzin ver"), in both orders. Expect a working session; the next reconnect is silent PAIRED.
  4. **Orphan / Parsec flow.** After "Onaylı cihazları unut": "Eşleş" → see the code → Home (or switch to Parsec) → "İzin ver" on the Mac → return to the app. Expect **no automatic connect** (no new approval window on the Mac) and the stored-code prompt with the **same code**; after "Kodlar aynı — Güven", a PAIRED session with video. Also once: confirm on the tablet before leaving, then approve on the Mac, then return → the "Mac'te 'İzin ver' dedikten sonra 'Bağlan'a bas" prompt; one "Bağlan" tap → PAIRED with video, no code screen.
     4b. **Early return.** After "Onaylı cihazları unut": "Eşleş" → see the code → switch to Parsec → switch **back to MateBridge before** clicking "İzin ver" → back to Parsec, click "İzin ver" → return to MateBridge. Expect: the code in the Mac's window never changes from what the tablet shows (no automatic reconnect re-rolls it; `approval_pending` appears once in `host.log`); final state after "Kodlar aynı — Güven" is a PAIRED session with video.
  5. **New host.** Make the second identity the **only** advertiser: quit MateBridge in the primary user's session (or, if T-189 has merged, set the real host to "Yalnız USB" so it does not advertise), and check with `dns-sd -B _matebridge._tcp` that exactly one instance is listed. Tablet in Wi-Fi mode (or AUTO without USB); "Bağlan" without a typed address. Expect "Kendini '…' olarak tanıtan bir Mac eşleşmek istiyor — Eşleş / Yoksay" with the second instance's name as a claim; the tablet never becomes ACCEPTED without "Eşleş" plus "Kodlar aynı — Güven". Then tap "Yoksay" and start the real host again (or turn its Wi-Fi listening back on): expect a silent PAIRED session with the real Mac and no new prompt for the second instance.
  6. **Localhost squatter on 47001.** With the reverse redirected to the second instance (see above), the real host still reachable on Wi-Fi, file sharing on and the app in the foreground, start AUTO and USB mode in turn. Expect no pending record, no FILES_INFO (`files … info state=ready` absent from the second instance's `host.log`), no input to the second instance. In AUTO: the prompt stays as a banner and the tablet falls back to Wi-Fi and reaches the real Mac (silent PAIRED). In USB mode: `PairingNeedsUser` with "Eşleş / Yoksay". Optionally tap "Eşleş" without confirming: still no FILES_INFO.
  7. **AUTO USB↔Wi-Fi migration (T-205 migration gate).** Real Mac, AUTO mode, start on Wi-Fi, plug USB. Expect the migration to USB with video continuing (one new video connection, no keyframe storm), and the fallback to Wi-Fi on unplug. No stuck key or pen on the Mac across the switch.
  8. **Proof-first PAIRED (T-152).** Normal reconnect: video appears (about +1 RTT); in `host.log`, `session_started` follows the first record (no `session_started` without a proof).
  9. **"Bu Mac'i unut" on the tablet (T-151, T-150).** Twice: once idle (session not streaming) and once in-stream from the settings panel; in-stream, hold Shift on the keyboard (or keep the pen on the screen) while tapping the second confirm. Expect: the session ends cleanly (BYE in `host.log`, no stuck key, button or pen on the Mac), the forget-done text appears; the next connect shows the `KEY_MISSING` text until the Mac also uses "Onaylı cihazları unut", after which the tablet shows "Eşleş".
  10. **KEY_MISMATCH (T-156).** From the end state of step 2 (the Mac holds the cancelled key, the tablet its old key): tap "Bağlan". Expect three silent automatic retries (`record_auth_failed` or a close without BYE in `host.log`), then the "Bu Mac'in anahtarı uyuşmuyor…" text and no further reconnect. Repeat once in AUTO on USB if practical: expect the fallback to Wi-Fi instead of a terminal state on USB.
  11. **Replaced orphan request (T-155).** With an orphan window open from the tablet (step 4 up to "Home"), launch the APK on a second Android device (phone, sideloaded) on the same Wi-Fi and tap "Eşleş" there. Expect the Mac panel to say "Bu, önceki istekten FARKLI bir cihaz" with a fingerprint; do not approve it. If no second device is available, record "not run" (the T-155 XCTests are the evidence).
- **Privacy check (all steps).** Grep both logs for the 6-digit codes shown during the run, for `token`, and for key-like hex: nothing may match. Never commit raw logs (AGENTS.md).
- **Watch for:** the host timing out an accepted session while the tablet waits for local confirmation (none expected: PINGs every 500 ms, host silence limit 5 s), and the Mac approval window flashing on automatic aborts (step 2).

## Kapsam dışı

- Code changes; any failure is fixed in the responsible card (reopened) or a new card.
- File folder scope (T-190) and the USB-only profile (T-189).

## Kabul kriterleri

- [ ] [device] Steps 1–11 (with 4b) were run once each (step 11 may be "not run" without a second Android device) on the installed build pair; each is recorded in `docs/NOTES.md` (dated entry) with the host and APK SHAs, what both screens showed, the relevant log events and pass/fail.
- [ ] [device] Steps 2, 5 and 6: no input injected, no clipboard and no FILES_INFO reached the Mac or the second instance without the user's "Eşleş" **and** "Kodlar aynı — Güven".
- [ ] [device] Step 4 and 4b (orphan/Parsec flow, the Mac's code never re-rolled by an automatic reconnect) and step 7 (AUTO migration) work as before the D2 changes.
- [ ] [device] Steps 9 and 10: forgetting in-stream leaves nothing stuck on the Mac; `KEY_MISMATCH` appears after three failures and stops retrying.
- [ ] [device] No key, SAS or token appears in `host.log` or the client log of the whole run.
- [ ] [doc] Any failed step is listed under *Açık sorular* with the card it reopens; D2 cards are set to `done` only after every step passed.

## Plan

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
