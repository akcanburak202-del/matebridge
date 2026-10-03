---
id: T-157
title: Run the trust-transition device acceptance (X1)
status: todo
phase: 6
owner: orchestrator
depends_on: [T-150, T-151, T-152, T-153, T-155]
decisions: [0018]
files:
  - docs/NOTES.md
  - backlog/tasks/T-157-trust-device-acceptance.md
---

## Amaç

The D2 cards change who the tablet trusts and when, and most of it is proven only by JVM and XCTest scripts. This card is the device evidence that the trust boundary holds on the real Mac mini and MatePad: a forgotten or fake Mac never gets input, clipboard or the file token without the user's pick and code confirmation, the Parsec/orphan flow still works, AUTO USB↔Wi-Fi migration still works, and a normal reconnect still shows video. It is the merge gate for D2: the D2 cards (T-150 … T-156) are set to `done` only after this run passes, and a failed step reopens the responsible card. The orchestrator runs the procedure; the user performs the taps and clicks.

Source: external architecture review 2026-10-03 (X1, H01, D2); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-4, X1 corrections) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§1–3).
Decision 0018 must be accepted by the user before work starts.
Gated: start only after T-150, T-151, T-152, T-153 and T-155 are merged and one APK plus one host bundle from that `main` are installed (T-150 and T-151 back-to-back; no APK between them).

## Bağlam

- **Setup and logs.** One device test at a time (CLAUDE.md). Record the `app_start` lines (T-145/T-146, if merged) or the commit SHAs of the installed APK and host bundle. Client log: `adb logcat -s 'MB/*'`; host log: `~/Library/Logs/MateBridge/host.log`. The exact client event names come from T-150/T-151 Handoff (e.g. `pair_pending_stored`, `pair_trust_confirmed`, `pair_trust_cancelled`, `pairing_needs_user`); `pair_key_stored` must not appear any more.
- **Second host identity (steps 5 and 6).** There is no host knob for a separate identity. Use a second macOS user account running its own `MateBridge.app` (own Keychain and defaults → own `host_id`), or a second Mac. On the same Mac the second instance finds 47001/47002 busy and takes system ports (PROTOCOL §3.1); read them from its `listening` line or `dns-sd -B _matebridge._tcp` / `lsof -iTCP -sTCP:LISTEN`. Do not approve anything on it.
- **Localhost squatter (step 6).** Turn "USB modu" off in the real host's menu so it stops re-adding `adb reverse`, run `adb reverse --remove tcp:47001`, then `adb reverse tcp:47001 tcp:<second instance control port>`. From the tablet this is wire-identical to a tablet app squatting `127.0.0.1:47001` (A2 §2), with no extra tooling. Afterwards restore with `adb reverse --remove-all` and "USB modu" back on.
- **Procedure** (for each step record: what the tablet showed, what the Mac showed, the relevant log events, pass/fail):
  1. **Paired baseline.** Kill and relaunch the tablet app. Expect a silent PAIRED reconnect (`handshake mode=paired` in `host.log`), no code screen, video and input working.
  2. **Mac forgets the tablet (same-`host_id` PAIRING).** Mac menu "Onaylı cihazları unut". Expect the tablet's automatic reconnect to show "Mac yeniden eşleşmek istiyor — Eşleş" (not automatic pairing); the Mac may flash an approval window (orphan, 2 min; known T-151 risk). Tap "Eşleş" → code screen with the key-changed warning. Tap "İptal": pending dropped, trusted key kept, nothing injected on the Mac. Then tap "Eşleş" again, and on the Mac click "İzin ver" **without** confirming on the tablet: the tablet stays on the code screen, no input, clipboard or FILES_INFO reaches the Mac (`input_session_end` counts 0, no `files … info state=ready`).
  3. **Real re-pair.** Repeat step 2 but confirm on both sides ("Kodlar aynı — Güven" + "İzin ver"), in both orders. Expect a working session; the next reconnect is silent PAIRED.
  4. **Orphan / Parsec flow.** After "Onaylı cihazları unut": "Eşleş" → see the code → Home (or switch to Parsec) → "İzin ver" on the Mac → return to the app. Expect the confirm prompt with the **same stored code**; after confirm, a PAIRED session with video. Also once: confirm on the tablet before leaving, then approve on the Mac, then return → silent PAIRED.
  5. **New host.** With the second identity advertising on Wi-Fi and the tablet in Wi-Fi mode (or AUTO without USB), disconnect from the real Mac. Expect "Yeni Mac bulundu — Eşleş" with the second instance's name as a claim; the tablet never becomes ACCEPTED without "Eşleş" plus "Kodlar aynı — Güven".
  6. **Localhost squatter on 47001.** With the reverse redirected to the second instance (see above), file sharing on and the app in the foreground, start AUTO and USB mode in turn. Expect `PairingNeedsUser`, no pending record, no FILES_INFO (`files … info state=ready` absent from the second instance's `host.log`), no input. Optionally tap "Eşleş" without confirming: still no FILES_INFO.
  7. **AUTO USB↔Wi-Fi migration (T-150 migration gate).** Real Mac, AUTO mode, start on Wi-Fi, plug USB. Expect the migration to USB with video continuing (one new video connection, no keyframe storm), and the fallback to Wi-Fi on unplug. No stuck key or pen on the Mac across the switch.
  8. **Proof-first PAIRED (T-152).** Normal reconnect: video appears (about +1 RTT); in `host.log`, `session_started` follows the first record (no `session_started` without a proof).
- **Privacy check (all steps).** Grep both logs for the 6-digit codes shown during the run, for `token`, and for key-like hex: nothing may match. Never commit raw logs (AGENTS.md).
- **Watch for:** the host timing out an accepted session while the tablet waits for local confirmation (none expected: PINGs every 500 ms, host silence limit 5 s), and the Mac approval window flashing on automatic aborts (step 2).

## Kapsam dışı

- Code changes; any failure is fixed in the responsible card (reopened) or a new card.
- File folder scope (T-190) and the USB-only profile (T-189).

## Kabul kriterleri

- [ ] [device] Steps 1–8 were run once each on the installed build pair; each is recorded in `docs/NOTES.md` (dated entry) with the host and APK SHAs, what both screens showed, the relevant log events and pass/fail.
- [ ] [device] Steps 2, 5 and 6: no input injected, no clipboard and no FILES_INFO reached the Mac or the second instance without the user's "Eşleş" **and** "Kodlar aynı — Güven".
- [ ] [device] Step 4 (orphan/Parsec flow) and step 7 (AUTO migration) work as before the D2 changes.
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
