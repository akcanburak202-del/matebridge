---
id: T-151
title: Add pairing confirm/cancel, the new-host pick prompt and "Bu Mac'i unut"
status: review
phase: 6
owner: android-client-dev
depends_on: [T-150]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionUi.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/WakeConnect.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/MacDiscovery.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/AutoTransport.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/TrustUiText.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/
  - backlog/tasks/T-151-client-trust-ui.md
---

## Amaç

T-150 makes the tablet refuse to trust a Mac until the user confirms the pairing code, and refuses to pair on connections the user did not start. This card gives the user the controls for that: "Kodlar aynı — Güven" and "İptal" on the pairing screen, a clear "Yeni Mac bulundu / Mac yeniden eşleşmek istiyor — Eşleş" prompt when an automatic connection meets a pairing request, a distinct warning when a known Mac's key changed, the stored code again when the user returns from Parsec (with no automatic connect until the user acts), a clear text after a cancelled pairing, a way to dismiss or ignore a pairing request so one impostor cannot park the tablet, and "Bu Mac'i unut" in settings (also in-stream, ending the session cleanly first). Normal PAIRED reconnects stay silent.

Source: external architecture review 2026-10-03 (H01, D2); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-2, additional issue A2) and docs/reviews/2026-10-03/verify-A2-adversarial.md (§1).
Decision 0018 must be accepted by the user before work starts (manifest §5 Q3).
**T-150 and T-151 must merge back-to-back; do not install an APK between them.** Without this card every PAIRING answer after T-150 ends in a state the user cannot act on.

## Bağlam

`C/` = `client-android/app/src/main/kotlin/dev/matebridge/client/`. Lines are at HEAD a30c769; T-150 lands first and moves some of them.

- **Evidence (today):**
  - `C/MainActivity.kt:2053-2070` `pairingText`: static text with the code, the amber line "Mac bu tableti tanımıyor, yeniden eşleşiliyor" for re-pairing (blames the Mac, not a key change), "Mac'te İzin ver dediğinde bağlanır" and the Parsec hint. No button.
  - The `AwaitingApproval` render is `MainActivity.kt:1897-1898`; status text `applyStatusText` :1892-1914.
  - `onDiscovered` (`MainActivity.kt:1803-1809`) connects to any discovered service while Searching/Disconnected; `WakeConnect.onDiscovered` (`C/session/WakeConnect.kt:127-134`) decides that; `MacDiscovery` resolves every `_matebridge._tcp` IPv4 service (`C/session/MacDiscovery.kt:105-122`).
  - Connect call sites: `connect(ep)` (`MainActivity.kt:1850-1857`) from the saved Wi-Fi endpoint (:1536), USB (:1548), discovery (:1807) and "Bağlan" (:1836); the wake attempt calls `controller.start` directly (:1990).
  - `AutoUsbPolicy.stageOf` maps `AwaitingApproval` to `WAITING_USER` (`C/session/AutoTransport.kt:245`), and `onProbeOpen` ignores it (:268). T-150 adds compile-only mappings for its new state; this card makes them deliberate and tested.
  - There is no "forget this Mac" on the tablet; recovery from a bad pairing is only the Mac menu's "Onaylı cihazları unut".
- **What T-150 provides (use, do not re-implement):** `SessionController.start(ep, wake, userInitiated)`, `confirmTrust()`, `cancelTrust()`, `forgetCurrentHost()` (ends a live session with BYE + close before forgetting), the `ConfirmPromptVisible(visible)` entry point (the machine owns the 2-min timeout and counts only visible time); UI states `AwaitingApproval(…, needsLocalConfirm)` (live connection), the connection-less `StoredTrust(code, confirmed)` (fresh pending record or awaiting-host marker; T-150 blocks every non-user-initiated start while it holds), `PairingNeedsUser(hostName, rePair)`, and `Failed(PAIR_CANCELLED)` (terminal after Cancel or timeout).
- **Which connects are user-initiated:** only the "Eşleş" action (to the endpoint that answered PAIRING), the actions on `StoredTrust` ("Kodlar aynı — Güven" then connect, "Yeniden eşleş", "Bağlan"), and "Bağlan" with an address the user typed. Discovery, the saved Wi-Fi endpoint, USB mode, the AUTO probe/switch, the wake connect and "Bağlan" without a typed address (`restartUsualWay`, :1844-1848) are not. Put this mapping in a small pure function so it is tested. Keep auto-connect itself: a PAIRED reconnect stays silent; only a PAIRING answer needs the pick.
- **Return to the foreground with an unresolved pairing (decision 0018; T-150 rule).** `onStart` → `applyTransport()` (`MainActivity.kt:1501`) still runs, but T-150 turns its non-user-initiated start into `StoredTrust` without opening a connection. Render it:
  - `confirmed = false`: the stored code, "Kodlar aynı — Güven", "İptal" and "Yeniden eşleş". Nothing connects until one of them is tapped.
  - `confirmed = true` (the user confirmed before leaving, the Mac has not been seen to approve): "Mac'te 'İzin ver' dedikten sonra 'Bağlan'a bas" with "Bağlan".
- **One impostor must not park the tablet (QA-1 T-151 #1).** Today `PairingNeedsUser` never retries (T-150), `WakeConnect.onDiscovered` connects only when `current == null || disconnected` (`C/session/WakeConnect.kt:127-134`), and in AUTO `shouldFallBack` fires only on `Disconnected` (`AutoTransport.kt:272-273`). So the first Bonjour impostor, or a localhost squatter on 47001 at every `onStart` probe, would hold the tablet on "Eşleş" while the real Mac is ignored. Rules:
  - The prompt for a `PairingNeedsUser` from a non-user-initiated connection has "Eşleş" and "Yoksay". "Yoksay" dismisses it, and the endpoint that answered PAIRING is not auto-connected again in this process (until a user start: "Eşleş", "Bağlan" or a typed address). Showing the prompt also counts that endpoint as asked once: automatic connects never go back to it on their own (each would raise a new dialog on a real Mac).
  - While that prompt is shown, discovery keeps running and automatic connects to **other** endpoints continue (non-user-initiated). One that answers PAIRED with the trusted key connects silently and replaces the prompt.
  - In AUTO, `PairingNeedsUser` on the USB endpoint falls back to Wi-Fi like `Disconnected` (`AutoUsbPolicy.shouldFallBack`); the prompt stays as a non-blocking banner.
- **Prompt visibility.** Post `ConfirmPromptVisible(true)` when a confirm prompt (`AwaitingApproval(needsLocalConfirm = true)` or `StoredTrust`) is rendered while the activity is started, and `false` when it is replaced or on `onStop`. Put the decision in a pure helper so it is tested.
- **Text and state mapping in a pure helper.** UI log events in `MainActivity` are not JVM-testable, so the state → text/buttons mapping (including the key-changed warning, the stored-code prompt, the Parsec hint and `PAIR_CANCELLED`) lives in a new pure `C/session/TrustUiText.kt` (it returns text identifiers and button sets; `MainActivity` resolves them from `strings.xml` and only renders the result). The prompt-visibility decision and the `hostReached` predicate below can live there too. The MbLog grep test covers its log fields.
- **USB hint.** `hostReached` is set only for `AwaitingApproval|Connected|Failed` (`MainActivity.kt:1876`), so in USB mode `showUsbHint` (`:1910-1912`) would overwrite the prompt. Include `PairingNeedsUser` and `StoredTrust` in the `hostReached` condition.
- **Texts (Turkish, `strings.xml`):**
  - Pairing screen buttons: "Kodlar aynı — Güven" and "İptal".
  - Known `host_id` (`rePair`): "Bu Mac'in kimliği/anahtarı değişti. Kodu Mac'teki ile karşılaştırmadan onaylama." (replaces the amber "Mac bu tableti tanımıyor" line).
  - Parsec hint: "Kodu tabletteki ile karşılaştır, Mac'te İzin ver, buraya dönüp 'Kodlar aynı'ya bas."
  - New-host prompt: the host name is chosen by whoever answered, so show it as a claim (e.g. "Kendini 'X' olarak tanıtan bir Mac eşleşmek istiyor") with "Eşleş" and "Yoksay".
  - `StoredTrust`: "Yeniden eşleş" next to the two pairing buttons; for `confirmed = true`: "Mac'te 'İzin ver' dedikten sonra 'Bağlan'a bas."
  - `PAIR_CANCELLED`: "Eşleşme iptal edildi. Mac'teki onay penceresinde 'Reddet' de; 'İzin ver'e bastıysan Mac menüsünden 'Onaylı cihazları unut' de."
  - "Bu Mac'i unut": 2-step confirm; afterwards say that the Mac must also use "Onaylı cihazları unut" before pairing again (otherwise the Mac answers PAIRED and the tablet shows KEY_MISSING). The row is also reachable in-stream (`SettingsCatalog.sections(h, inStream)`); there T-150's `forgetCurrentHost()` ends the session first.
  - The code is never logged; button taps may log `ev=pair_ui action=confirm|cancel|pair|forget` without values.
- **Risk:** when the tablet aborts an automatic PAIRING, the Mac has already shown its approval dialog; it stays open as an orphan window ("Tablet ayrıldı…", `ApprovalPanel.markDisconnected`) for 2 min. Accept this and note it for T-157; T-155 makes a replaced request visible.
- `MacDiscovery.kt` is listed in case the prompt needs the service name; change it only if needed.
- **Serialize with:** T-146 (same files `MainActivity.kt`, `SettingsCatalog.kt`), T-150 (same files `MainActivity.kt`, `SessionUi.kt`, `AutoTransport.kt`, `WakeConnect.kt`; depends_on), T-153 and T-156 (same file `MainActivity.kt`; both depend on this card, chain T-146 → T-150 → T-151 → T-153 → T-159 …), T-156 also on `SessionUi.kt` and `strings.xml`, T-159 (`strings.xml`), T-190/T-191 (`SettingsCatalog.kt`).
- No wire change; `docs/PROTOCOL.md` prose for 0018 is done by the orchestrator before T-150. `docs/LOGGING.md` additions go under *Açık sorular*.

## Kapsam dışı

- Trust state logic and stores (T-150); the migration gate (T-205); Mac UI (T-155); `KEY_MISMATCH` (T-156); file-server lifetime (T-153).
- Persisting the last `host_id` across app restarts for "Bu Mac'i unut" (if the row cannot be offered without it, hide it and note it under *Açık sorular*).

## Kabul kriterleri

- [ ] [JVM] UI-state mapping: `AwaitingApproval(needsLocalConfirm = true)` renders the code with "Kodlar aynı — Güven" (→ `confirmTrust()`) and "İptal" (→ `cancelTrust()`); `PairingNeedsUser(hostName, rePair)` renders the host name as a claim and "Eşleş"; tapping "Eşleş" calls `start(ep, userInitiated = true)` for the endpoint that answered.
- [ ] [JVM] Connect origins: only "Eşleş", the `StoredTrust` actions and "Bağlan" with a typed address are user-initiated; discovery, the saved Wi-Fi endpoint, USB mode, the AUTO probe/switch, the wake connect and "Bağlan" without a typed address are not (pure mapping, tested).
- [ ] [JVM] WakeConnect / AutoTransport: a discovered service, a saved endpoint or the USB probe never starts pairing on its own; `AwaitingApproval` with a pending local confirm, `StoredTrust` and `PairingNeedsUser` map to `WAITING_USER` (no probe, no migrate) and are ignored by `onProbeOpen`.
- [ ] [JVM] **Impostor cannot park the tablet (QA-1 T-151 #1).** While `PairingNeedsUser` from a non-user-initiated connection is shown, discovery keeps running; another discovered service that answers PAIRED with the trusted key connects silently and replaces the prompt; the endpoint that answered PAIRING is not auto-connected again; "Yoksay" dismisses the prompt and keeps that endpoint out of automatic connects until a user start to it. In AUTO, `PairingNeedsUser` on the USB endpoint makes `shouldFallBack` true (fallback to Wi-Fi), with the prompt kept as a banner.
- [ ] [JVM] **Return with an unresolved pairing.** `StoredTrust(code, confirmed = false)` renders the stored code with "Kodlar aynı — Güven" (→ `confirmTrust()`, then a user-initiated connect), "İptal" (→ `cancelTrust()`) and "Yeniden eşleş" (→ user-initiated start); `StoredTrust(confirmed = true)` renders the "Bağlan" text and button (→ user-initiated start). No connection is opened before a tap.
- [ ] [JVM] **Prompt visibility.** Rendering a confirm prompt while started posts `ConfirmPromptVisible(true)`; replacing it, or `onStop`, posts `false` (pure helper, tested).
- [ ] [JVM] "Bu Mac'i unut" calls `forgetCurrentHost()` only after a 2-step confirm; cancelling at either step changes nothing. Forget while `Connected` (in-stream) ends the session first (T-150), then removes the records; the UI goes to the forget-done text.
- [ ] [JVM] `TrustUiText`: a known `host_id` (`rePair`) gives "Bu Mac'in kimliği/anahtarı değişti. Kodu Mac'teki ile karşılaştırmadan onaylama."; the stored-code prompt, the Parsec hint, the `PAIR_CANCELLED` text and the new-host claim map as listed above.
- [ ] [JVM] The `hostReached` predicate (pure) includes `PairingNeedsUser` and `StoredTrust`, so the USB hint never replaces the prompt.
- [ ] [build] All new texts are in `strings.xml`.
- [ ] [JVM] No code, key or token is logged (existing MbLog grep test extended to the `TrustUiText` / `pair_ui` log fields).
- [ ] [device] Covered by T-157 (steps 1–6 and 9).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **`C/session/TrustUiText.kt` (new, pure):**
   - `TrustText` (string ids) / `TrustButton` / `TrustLine` / `TrustView`; `TrustUiText.view(state)` maps `AwaitingApproval(code, rePairing, needsLocalConfirm)`, `PairingNeedsUser` (host name as a sanitised claim), `StoredTrust(confirmed=false|true)` and `Failed(PAIR_CANCELLED)` to texts + buttons; `pickView(prompt)` for the non-blocking banner; `hostReached(state)` (+ `PairingNeedsUser`, `StoredTrust`); `claimName()` (no control/bidi chars, length cap).
   - `ConnectOrigin` enum + `forConnectButton(typed, fieldVisible)`: only PAIR, STORED_REPAIR/STORED_CONNECT and TYPED_ADDRESS are `userInitiated`; DISCOVERY, SAVED_WIFI, USB_MODE, AUTO_SWITCH, WAKE, CONNECT_BUTTON are not; automatic ones are subject to the pick gate, "Bağlan" clears it.
   - `PairPick`: last `Connecting` endpoint → the endpoint that answered PAIRING; `asked` set (bounded) that automatic connects skip; `seen` discovered endpoints (bounded) → `nextAuto()` so a parked prompt does not hide the real Mac; `ignore()` / `pair()` / `onUserStart()`; prompt cleared by `Connected`/`AwaitingApproval`/`StoredTrust`.
   - `PromptVisibility` (post `true`/`false` only on change; `onStop`), `ForgetFlow` (2-step confirm, result text), `pairUiFields(action)` for `ev=pair_ui`.
2. **`AutoTransport.kt`:** `shouldFallBack` also for `PairingNeedsUser`; `next(..., usbBlocked)` and `onProbeOpen(ui, usbBlocked)` never go to an asked USB endpoint. **`WakeConnect.onDiscovered(..., atPairPrompt)`**: a pairing prompt frees the slot for another endpoint.
3. **`MainActivity.kt`:** `connect(ep, origin)` (gate + `userInitiated`), all call sites pass their origin; trust button row built in code under the status text; status text from `TrustView` via `strings.xml`; main "Bağlan" hidden while the trust row has buttons; prompt-visibility posts in `render`/`onStop`; Eşleş/Yoksay/Güven/İptal/Yeniden eşleş/Bağlan handlers (`ev=pair_ui action=`); AUTO initial pick and wake target skip an asked endpoint; fallback on `PairingNeedsUser`; "Bu Mac'i unut" via two `AlertDialog`s → `forgetCurrentHost()` → like "Bağlantıyı kes" + forget-done text.
4. **`SettingsCatalog.kt`:** `forget_host` action in Bağlantı (both panels), label from the host (`strings.xml`).
5. **`strings.xml`:** all new texts. **Tests:** `TrustUiTextTest`, `PairPickTest` (impostor, origins, visibility, forget), `AutoTransportTest`/`WakeConnectTest`/`SettingsCatalogTest` additions, log-field scan of `pair_ui` lines.
6. Risks: `MainActivity` overlap with T-159 (kept local); no public "can forget" getter on the controller → the row is always shown and an unknown Mac gives a "nothing to forget" text (Açık sorular).

## Handoff

- **Commit:** `26df194` (forget result from the UI state + "Yoksay" fix), on top of `c526a45` (T-150 API adaptation), `5a90aed` (implementation) and plan `a24de76`. Branch `task/T-151-client-trust-ui` merges `task/T-150-client-pending-pair-trust` three times (`7f60ffb` at `f2c24da`, `49eee37` at `61d598b`, `3182217` at `f009834`). `./scripts/check.sh: ALL OK` after the third merge.
- **Dokunulan dosyalar:** `C/session/TrustUiText.kt` (new: `TrustText`/`TrustButton`/`TrustLine`/`TrustView`, `TrustUiText.view/screen/pickView/claimName/hostReached/pairUiFields`, `ConnectOrigin`, `PairPick`, `PromptVisibility`, `ForgetFlow`), `C/session/AutoTransport.kt` (`next(..., usbBlocked)`, `onProbeOpen(ui, usbBlocked)`, `shouldFallBack` also on `PairingNeedsUser`), `C/session/WakeConnect.kt` (`onDiscovered(..., atPairPrompt)`), `C/settings/SettingsCatalog.kt` (`forget_host` action in Bağlantı, both panels; `SettingsHost.forgetHostLabel`/`forgetHost()`), `C/MainActivity.kt`, `res/values/strings.xml`; tests: new `test/session/TrustUiTest.kt` (22), additions in `AutoTransportTest` (3), `WakeConnectTest` (1), `SettingsCatalogTest` (1 + key list). `SessionUi.kt` and `MacDiscovery.kt` unchanged.
- **Varsayımlar:**
  - **T-150 update (61d598b):** "Kodlar aynı — Güven"/"İptal" call `confirmTrust(promptGen)`/`cancelTrust(promptGen)` with `TrustUiText.promptGen(lastUi)`, i.e. the generation of the `AwaitingApproval`/`StoredTrust` on screen (`lastUi` is what was rendered; -1 otherwise). **Cancel latch:** "Bağlan" on `Failed(PAIR_CANCELLED)` is the new origin `CONNECT_AFTER_CANCEL` (user-initiated, clears the gate), so it releases the latch; automatic starts (onStart, discovery, USB probe, wake) stay non-user-initiated and only re-show the cancelled text. "Bağlan" elsewhere without a typed address stays non-user-initiated as the card says (a PAIRING answer then gives the Eşleş prompt). Edge: after İptal and then "Bağlantıyı kes", the first "Bağlan" re-applies the mode's usual (automatic) way and shows "Eşleşme iptal edildi" again; the second tap releases the latch.
  - **Origins:** every `controller.start` goes through `connect(ep, origin)` (wake: `ConnectOrigin.WAKE`). User-initiated: "Eşleş" (`PAIR`), stored-prompt "Yeniden eşleş"/"Bağlan" (`STORED_REPAIR`/`STORED_CONNECT`, to `currentEndpoint` = the blocked start's endpoint), "Bağlan" with an address in the **open** manual field (`TYPED_ADDRESS`). A hidden field's remembered address counts as plain "Bağlan" (`CONNECT_BUTTON`, not user-initiated), like T-134's wake rule. "Kodlar aynı — Güven" on `StoredTrust` is only `confirmTrust()`: the machine (T-150) promotes and connects, user-initiated, to its blocked endpoint.
  - **Pick gate:** the endpoint of the latest `Connecting` is the one that answered PAIRING (the machine emits states in order). Asked endpoints are kept per activity instance (landscape-locked, so practically the process), bounded to 16; discovered endpoints are remembered (bounded to 8, cleared per discovery run) so a prompt triggers an immediate automatic try of another discovered Mac (`tryNextAfterPick`), because NSD reports a service only once. Any "Bağlan" tap (typed or not) clears the whole asked set; "Eşleş" clears its own endpoint. "Yoksay" only dismisses. The prompt stays as a banner (text under the state text, Eşleş/Yoksay) until `Connected`/`AwaitingApproval`/`StoredTrust`, "Bağlantıyı kes" or forget. It survives `onStop`/`onStart` (the asked endpoint is not re-contacted, so the user needs it to pair).
  - **AUTO/USB:** an asked loopback endpoint → initial pick goes Wi-Fi (`transport_pick reason=usb_asked`), no rescan probe/switch/migration; `PairingNeedsUser` on USB in AUTO falls back to Wi-Fi (also stops the USB session when no eligible Wi-Fi endpoint). Manual USB mode with an asked loopback: no connect, `Idle` + banner, "Bağlan" reconnects.
  - **Buttons:** built in code under the status text (the layout file is outside the card). The plain "Bağlan" is hidden while the trust row has buttons. `AwaitingApproval(needsLocalConfirm = false)` shows the code + "Mac'te İzin ver dediğinde bağlanır" without buttons (T-150 offers no cancel there).
  - **Forget (T-150 f009834):** two `AlertDialog`s → `forgetCurrentHost()`. `false` → toast "unutulacak Mac yok". `true` only queues the request (`ForgetFlow.Step.WAITING`); the result comes from the rendered state: `Idle` → done (then "Bağlantıyı kes" behaviour, no automatic reconnect, forget-done text); `Failed(KEY_STORE_FAILED)` → "Mac unutulamadı … yeniden dene" text instead of the pairing-key text, the row stays usable (retry works). An already idle machine shows no state on success, so a request with no failure after `ForgetFlow.SETTLE_MS` (1.5 s; the engine takes the trust mailbox within one 100 ms tick) counts as done; a `KEY_STORE_FAILED` within 10 s after that still turns it into the failure text. `onStop` abandons a waiting request (nothing reported). The row is always shown (no public "can forget" getter, see below).
  - **"Yoksay" (Codex P2):** on a `PairingNeedsUser` screen it renders `TrustUiText.afterIgnore(discovery running)` = `Searching` (or `Idle` with no discovery, e.g. manual USB) and drops `currentEndpoint` (the prompt holds no connection), so the ordinary screen and "Bağlan" come back and discovery/wake/AUTO go on to other Macs; the ignored endpoint stays asked. `TrustUiText.screen` also shows a `PairingNeedsUser` only while `PairPick` holds its prompt, so a dismissed or unattributable one never shows dead buttons. "Bağlan" with no chosen endpoint and nothing typed now searches the usual way again (`restartUsualWay`) instead of the "Geçersiz adres" toast.
  - Host names are shown sanitised (`claimName`: no control/bidi/format chars, whitespace collapsed, ≤ 40 code points).
  - New log events (no values): `ev=pair_ui action=confirm|cancel|pair|ignore|repair|connect|forget`, `ev=pair_auto_skip origin=<origin>`; `ev=transport` got `origin=`; `transport_pick reason=usb_asked`.
- **Test edilmeyenler / cihazda doğrulanacaklar (nothing ran on the tablet; T-150 + T-151 installed together):**
  1. Paired Mac: silent PAIRED reconnect over USB, Wi-Fi and AUTO (no prompt, `transport ... origin=`, `connect_start user=0`).
  2. Mac "Onaylı cihazları unut" → tablet shows "Mac yeniden eşleşmek istiyor: kendini "<ad>" …" with Eşleş/Yoksay (Bağlan hidden); Eşleş → code + amber "Bu Mac'in kimliği/anahtarı değişti…" + "Kodlar aynı — Güven"/"İptal"; confirm before and after Mac "İzin ver" (both orders) → stream.
  3. Fresh tablet (no key): "Yeni Mac bulundu…" → Eşleş → pairing works end to end.
  4. Parsec flow: see code → Home → "İzin ver" in Parsec → back: stored code with Güven/İptal/Yeniden eşleş, no HELLO before the tap; Güven → connects. Confirm first then leave → back: "Mac'te 'İzin ver' dedikten sonra 'Bağlan'a bas" + Bağlan.
  5. İptal → "Eşleşme iptal edildi…" text; Home → back: no reconnect (`pair_cancel_latched`), "Bağlan" reconnects (`origin=connect_after_cancel`, `user=1`); Mac-side dialog shows "Tablet ayrıldı" (orphan, T-157).
  6. "Bu Mac'i unut" from the connect panel and in-stream: two dialogs, cancel at either changes nothing; confirm while streaming ends the stream cleanly (no stuck key/pen), shows the forget-done text; also from the connect panel while idle (done text after ~1.5 s); then Mac "Onaylı cihazları unut" + Bağlan → pick prompt → re-pair. The failure text cannot be provoked on the device without a broken store (JVM-tested only).
  7. Dialog/button layout at 2800×1840 (three buttons in one row), immersive mode after an AlertDialog.
  8. `adb logcat -s 'MB:*'` over all of the above: no code, key, token or Mac name.
  9. Impostor (optional, T-157): a second `_matebridge._tcp` answering PAIRING does not park the tablet (real Mac connects, banner disappears).
  10. "Yoksay" on a pick prompt: the ordinary "Mac aranıyor…" screen with "Bağlan" comes back; that Mac is not auto-connected again; "Bağlan" → it asks again.
- **Açık sorular:**
  - "Bağlan" user-initiated only on `Failed(PAIR_CANCELLED)` or with a typed address: accepted by the orchestrator (2026-10-03).
  - The idle-machine forget success is inferred from a 1.5 s settle window with no failure (T-150 emits no state then). A distinct "forget done" UI event from the controller would make it exact.
  - **"Can forget" getter:** `SessionController.forgettable` is private, so "Bu Mac'i unut" is always offered and an unknown Mac ends in a "nothing to forget" toast after both confirmations. A public `canForgetCurrentHost` (controller, outside this card) would let the row hide itself.
  - **docs/LOGGING.md (orchestrator):** add `pair_ui action=`, `pair_ui_forget_failed`, `pair_auto_skip origin=`, the `origin=` field on `transport`, and `transport_pick reason=usb_asked`.
  - The settings row label comes through `SettingsHost.forgetHostLabel` (strings.xml) while other catalog titles are still Kotlin literals.
  - T-157: the orphan approval window on the Mac after the tablet aborts an automatic PAIRING (accepted risk, per card).
