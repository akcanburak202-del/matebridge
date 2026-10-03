---
id: T-151
title: Add pairing confirm/cancel, the new-host pick prompt and "Bu Mac'i unut"
status: todo
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
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/
  - backlog/tasks/T-151-client-trust-ui.md
---

## Amaç

T-150 makes the tablet refuse to trust a Mac until the user confirms the pairing code, and refuses to pair on connections the user did not start. This card gives the user the controls for that: "Kodlar aynı — Güven" and "İptal" on the pairing screen, a clear "Yeni Mac bulundu / Mac yeniden eşleşmek istiyor — Eşleş" prompt when an automatic connection meets a pairing request, a distinct warning when a known Mac's key changed, the stored code again when the user returns from Parsec, and "Bu Mac'i unut" in settings. Normal PAIRED reconnects stay silent.

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
- **What T-150 provides (use, do not re-implement):** `SessionController.start(ep, wake, userInitiated)`, `confirmTrust()`, `cancelTrust()`, `forgetCurrentHost()`; UI states `AwaitingApproval(…, needsLocalConfirm)` (with the live or the stored code) and `PairingNeedsUser(hostName, rePair)`.
- **Which connects are user-initiated:** only the "Eşleş" action (to the endpoint that answered PAIRING) and "Bağlan" with an address the user typed. Discovery, the saved Wi-Fi endpoint, USB mode, the AUTO probe/switch, the wake connect and "Bağlan" without a typed address (`restartUsualWay`, :1844-1848) are not. Put this mapping in a small pure function so it is tested. Keep auto-connect itself: a PAIRED reconnect stays silent; only a PAIRING answer needs the pick.
- **Texts (Turkish, `strings.xml`):**
  - Pairing screen buttons: "Kodlar aynı — Güven" and "İptal".
  - Known `host_id` (`rePair`): "Bu Mac'in kimliği/anahtarı değişti. Kodu Mac'teki ile karşılaştırmadan onaylama." (replaces the amber "Mac bu tableti tanımıyor" line).
  - Parsec hint: "Kodu tabletteki ile karşılaştır, Mac'te İzin ver, buraya dönüp 'Kodlar aynı'ya bas."
  - New-host prompt: the host name is chosen by whoever answered, so show it as a claim (e.g. "Kendini 'X' olarak tanıtan bir Mac eşleşmek istiyor") with "Eşleş".
  - "Bu Mac'i unut": 2-step confirm; afterwards say that the Mac must also use "Onaylı cihazları unut" before pairing again (otherwise the Mac answers PAIRED and the tablet shows KEY_MISSING).
  - The code is never logged; button taps may log `ev=pair_ui action=confirm|cancel|pair|forget` without values.
- **Risk:** when the tablet aborts an automatic PAIRING, the Mac has already shown its approval dialog; it stays open as an orphan window ("Tablet ayrıldı…", `ApprovalPanel.markDisconnected`) for 2 min. Accept this and note it for T-157; T-155 makes a replaced request visible.
- `MacDiscovery.kt` is listed in case the prompt needs the service name; change it only if needed.
- **Serialize with:** T-146 (same files `MainActivity.kt`, `SettingsCatalog.kt`), T-153 and T-156 (same file `MainActivity.kt`; both depend on this card, chain T-146 → T-150 → T-151 → T-153 → T-159 …), T-191 (`SettingsCatalog.kt`).
- No wire change; `docs/PROTOCOL.md` prose for 0018 is done by the orchestrator before T-150. `docs/LOGGING.md` additions go under *Açık sorular*.

## Kapsam dışı

- Trust state logic, stores and the migration gate (T-150); Mac UI (T-155); `KEY_MISMATCH` (T-156); file-server lifetime (T-153).
- Persisting the last `host_id` across app restarts for "Bu Mac'i unut" (if the row cannot be offered without it, hide it and note it under *Açık sorular*).

## Kabul kriterleri

- [ ] [JVM] UI-state mapping: `AwaitingApproval(needsLocalConfirm = true)` renders the code with "Kodlar aynı — Güven" (→ `confirmTrust()`) and "İptal" (→ `cancelTrust()`); `PairingNeedsUser(hostName, rePair)` renders the host name as a claim and "Eşleş"; tapping "Eşleş" calls `start(ep, userInitiated = true)` for the endpoint that answered.
- [ ] [JVM] Connect origins: only "Eşleş" and "Bağlan" with a typed address are user-initiated; discovery, the saved Wi-Fi endpoint, USB mode, the AUTO probe/switch, the wake connect and "Bağlan" without a typed address are not (pure mapping, tested).
- [ ] [JVM] WakeConnect / AutoTransport: a discovered service, a saved endpoint or the USB probe never starts pairing on its own; `AwaitingApproval` with a pending local confirm and `PairingNeedsUser` both map to `WAITING_USER` (no probe, no migrate) and are ignored by `onProbeOpen`.
- [ ] [JVM] "Bu Mac'i unut" calls `forgetCurrentHost()` only after a 2-step confirm; cancelling at either step changes nothing.
- [ ] A known `host_id` shows "Bu Mac'in kimliği/anahtarı değişti. Kodu Mac'teki ile karşılaştırmadan onaylama."
- [ ] On return with an unconfirmed pending record, the stored code is shown with the same two buttons.
- [ ] The Parsec hint text is updated; all new texts are in `strings.xml`.
- [ ] No code, key or token is logged (existing MbLog grep test extended to the UI log events).
- [ ] [device] Covered by T-157 (steps 1–5 and 7).
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
