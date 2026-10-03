# Verifier A2: adversarial re-check of H01, local-squatter token, A1, SE1 (HEAD a30c769, read-only)

Paths are relative to `client-android/app/src/main/kotlin/dev/matebridge/client/` (C/) and `host-mac/Sources/` (H/).

## 1. H01: CONFIRMED (with tighter preconditions)

I tried to refute it in five ways. All five failed:

- **Is the key overwritten before confirmation?** Yes. C/security/Handshake.kt:131-149: for PAIRING, `stored` only sets `rePairing` (l.141). It is not an input to the KDF (l.142) and it is zeroed (l.144). Handshake.kt:67-77 `storePairKey` calls `store.put(hostId, …)` once, with no compare. C/session/SessionController.kt:662-677: in the reader thread, `storePairKey` runs right after the first plaintext PENDING ack. That is before `Secured` and `Received` are posted, so no UI or user step comes first.
- **Does an unauthenticated plaintext ACCEPTED open anything?** In PAIRING it cannot: Handshake.kt:126 forces the first ack to be PENDING_APPROVAL. But the attacker did the ECDH, so it holds `controlH2c` and can seal an ACCEPTED record. Such a record arrives through `readRecords` → `onAck` (C/session/SessionMachine.kt:299-320) → `Phase.ACCEPTED`, and `inputAllowed` becomes true (l.166). Nothing in that path is local to the tablet.
- **Is there any tablet-side check?** No. `pairingText` (C/MainActivity.kt:2053-2070) is static text. The `AwaitingApproval` render (l.1897) has no button. `SessionUi.AwaitingApproval` (SessionUi.kt:12) carries no confirm state. There is also no host_id↔endpoint pin.
- **What does the tablet send and accept after the fake ACCEPTED?**
  - `onAck` queues PING, STREAM_PREFS, DISPLAY_RATE, AUDIO_PREFS and `files` (= FILES_INFO READY+token when the DAV server listens) (l.306-310).
  - Input goes out through `trySendInput`, gated only on `inputAllowed` (SessionController.kt:278-293).
  - Inbound CLIPBOARD is gated only on `inputAllowed`, then `setPrimaryClip` (SessionController.kt:367; clipboard/ClipboardBridge.kt:82-85).
  - Outbound clipboard follows `render(Connected)` (MainActivity.kt:1860-1863).
- **Migration path (a refutation candidate that held).**
  - A T-096 candidate cannot pair: `candidateKeys.put` throws (SessionController.kt:155-160), and a PENDING ack aborts it (SessionMachine.kt:461-469).
  - Side finding: a candidate *is* promoted on the **plaintext** PAIRED/ACCEPTED first ack, before any authenticated host record (SessionMachine.kt:463 → `promote` l.492-511; SessionController.kt:677).
  - So a squatter on 127.0.0.1:47001 that knows the real host_id can steal a live Wi-Fi session in AUTO mode. AutoUsbPolicy migrates every interval while ACCEPTED and the cable is not reported DISCONNECTED (AutoTransport.kt:193-201).
  - The result is DoS only. Everything after that is sealed under pair_key, so the squatter gets ciphertext.
  - Getting the host_id is the hard part. BUSY acks carry no host_id (H/MateBridgeCore/Session/SessionMachine.swift:569-572), so it is only exposed in PAIRED/PAIRING acks.

**Does a newly discovered fake host (different host_id) capture input without user action?** Yes, under these conditions:
- **Transport path.** Discovery runs only on the Wi-Fi path: WIFI mode, or AUTO after the USB probe was closed (MainActivity.kt:1513-1537). In USB mode and AUTO-on-USB, discovery is stopped (l.1540-1543).
- **No picker.** `MacDiscovery` connects to every resolved `_matebridge._tcp` IPv4 service (MacDiscovery.kt:105-122). `onDiscovered` calls `connect(ep)` when `currentEndpoint == null || lastUi is Disconnected` (MainActivity.kt:1803-1809; WakeConnect.kt:127-134). The user never picks a host.
- **Timing.**
  - While the tablet is **Connected** or **Connecting** to the real Mac, a fake is ignored.
  - In **Searching** (app start, after "Bağlantıyı kes"→Bağlan) or **Disconnected** (any drop or retry wait, e.g. the Mac rebooting or sleeping before the HOST_SLEEP gate), the first resolved service wins.
  - An attacker can re-register under new service names so it keeps being "found".
- **Saved endpoint.** `lastWifiEndpoint` (in-memory, l.274/1536/1854) is retried directly, so anyone answering at that IP (DHCP or ARP takeover) is accepted too.
- **No other user step.** None is needed: the attacker sends PENDING(PAIRING) and the sealed ACCEPTED in one write.

**What the user would see:**
- **Different host_id:** the "Mac'teki kodla aynı mı? NNN NNN / Mac'te İzin ver…" screen. If ACCEPTED is coalesced with the first ack, this lasts a few ms or is never painted. It then turns into `state_connected` with the attacker's chosen `hostName` (e.g. "Mac mini") and a frame counter (MainActivity.kt:1899). There is no amber warning, because `rePairing` is false.
- **Same host_id as a stored Mac:** the same, plus the amber "Mac bu tableti tanımıyor, yeniden eşleşiliyor" line, but only if the attacker holds PENDING long enough to render. The wording blames the Mac, not a host-key change.
- **Video:** no frames unless the attacker sends STREAM_CONFIG and video. It cannot relay the real Mac's screen, because it has no Mac key and the Mac shows a different SAS. A convincing keystroke capture therefore needs a fake desktop. Without one, the user sees a "connected" black screen and pen strokes that do nothing, which is noticeable fairly quickly.
- **On the Mac:** nothing.

**Preconditions:**
- A LAN attacker able to answer mDNS, or to own the remembered IP, at a moment the tablet is Searching or Disconnected on the Wi-Fi path.
- Or a local app on the tablet (see item 2).
- The DoS/overwrite variant additionally needs the real host_id. That is in clear in PAIRED/PAIRING acks, so it can be sniffed on Wi-Fi or obtained by sending HELLO to the Mac while no session is live, which pops a Mac dialog.

## 2. Local squatter on 127.0.0.1:47001 gets the WebDAV token: CONFIRMED (it depends on H01)

**Who connects to 127.0.0.1:47001, and when** (`ConnectMode.usbEndpoint`, ConnectMode.kt:14-18):
- **USB mode:** always, through `startUsb` → `connect` (MainActivity.kt:1540-1548). It retries forever.
- **AUTO (the default):** `TransportMode.fromSetting` → AUTO, AutoTransport.kt:15.
  - On every `applyTransport`, which runs at activity start and on every mode change, an un-gated TCP probe runs (`probeUsb(initial=true)`, l.1524, 1597-1625). OPEN → `startUsb` (l.1632-1634). This probe ignores cable state.
  - The periodic rescan PROBEs when not connected and MIGRATEs when connected (AutoTransport.kt:193-201, MainActivity.kt:1670-1677). Both are skipped while the cable is reported DISCONNECTED.
  - PROBE OPEN while Searching/Idle/Disconnected → SWITCH to USB (AutoTransport.kt:265-269).

**Can a local app hold the port?**
- Yes, whenever adbd is not holding it: cable unplugged, Mac USB mode off, adb not yet authorised, or reverse removed. Any app with INTERNET can bind 127.0.0.1:47001 (unprivileged port).
- If the app binds first, the Mac's `adb reverse tcp:47001` (H/MateBridgeHost/Usb/UsbTunnelWatcher.swift:119) should then fail to bind on the device, so the squatter can keep the port. This is inferred from adbd behaviour and not tested here.

**Is the token or any secret sent before the peer is authenticated?**
- The token is sent only inside FILES_INFO, only after ACCEPTED (SessionMachine.kt:310, 264-269), and always sealed.
- But in PAIRING mode the tablet **never authenticates the host**. The handshake is unauthenticated ECDH plus a display-only SAS (Handshake.kt:136-148). The squatter derived the same `prk`, so it decrypts FILES_INFO.
- In PAIRED mode the squatter cannot read anything without pair_key. It either gets KEY_MISSING (unknown host_id, Handshake.kt:134) or ciphertext (real host_id). So the leak exists **only because of H01**. With a tablet-side confirm gate, the squatter would not get the token.

**Token value and scope:**
- `FilesController.startLocked` publishes `FilesInfo(READY, port, token)` as soon as the server listens (FilesController.kt:79-99).
- The server runs whenever the activity is in the foreground, sharing is on, and MANAGE_EXTERNAL_STORAGE is granted (l.40-47). This does not depend on the transport or on an accepted session.
- FILES_INFO is also not transport-gated on the client. A LAN fake host also receives the token but cannot reach the tablet loopback.
- With the token, DigestAuth (files/DigestAuth.kt:52, 72; Basic is accepted too) grants full DAV read/write on `Environment.getExternalStorageDirectory()` (FilesController.kt:84).
- This is a confused-deputy bypass of the app's own MANAGE_EXTERNAL_STORAGE grant.

**Decision 0015 item 3** explicitly states: "Jeton Mac'e yalnızca şifreli kontrol kanalında … gider … Böylece tabletteki başka uygulamalar localhost üzerinden dosyalara erişemez." That guarantee assumes the encrypted channel's peer is the Mac. Under H01, that assumption does not hold.

**Preconditions:**
- A malicious app installed on the tablet (INTERNET permission only).
- MateBridge in AUTO or USB mode, file sharing on, the permission granted, and the app in the foreground.
- The port free at bind time.

**User view:** as in item 1 (code flash, then "connected"). In USB mode this is identical to a normal start.

## 3. A1 (host activates non-takeover PAIRED before proof): CONFIRMED. Resource/DoS only, no data exposure

**How activation happens:**
- H/MateBridgeCore/Session/SessionMachine.swift:607-611: PAIRED is chosen from `approvedDevices.contains(deviceID)` plus the stored key. `device_id` is the only client-supplied selector and is cleartext in HELLO.
- l.649-668: with no slot owner, `takeover == false` → `start()` (l.726-735). That sets `.active`, sends STREAM_CONFIG and emits `.sessionStarted` with no authenticated record. Only `takeover` goes to `.proving` (l.660-665).

**Side effects** (H/MateBridgeHost/Session/StreamCoordinator.swift:307-328):
- The sleep gate opens ("awake reason=session_started").
- `displaySleep.hold()` runs.
- `lease.sessionStarted` → `.create(settings)` builds the virtual display and pipeline (H/…/DisplayLease.swift:37-47). Different HELLO settings cause teardown+create churn, which rearranges windows on the Mac.
- The session dies when the attacker's first record fails AEAD, or at `closeSilenceUs` = 5 s if it sends nothing (SessionMachine.swift:84-85).
- The lease grace is 10 s (DisplayLease.swift:9), so one HELLO about every 5-10 s keeps a virtual display alive indefinitely. While that session holds the slot, other new devices get BUSY.
- The real tablet is not locked out. Its PAIRED reconnect with the same device_id becomes a takeover, proves, and supersedes the attacker (l.629-641, 696-716).

**Exposure:** none.
- Input: the attacker cannot seal records, and the first bad record ends the session.
- Video: a video connection needs a proof under the video key derived from `prk`, which needs pair_key (PROTOCOL §9; host video proof).
- STREAM_CONFIG, clipboard, audio and anything else host→client on that connection are sealed under pair_key-derived keys.
- Files: the Mac acts on FILES_INFO only from an active session's authenticated records (`handleCommon` → `.deliver` after decrypt).

**Preconditions:**
- Network reach to the Mac's control port: LAN, since the host binds all interfaces, or via `adb reverse` from a tablet-local app.
- An approved tablet's `device_id`, which is a random stored value (C/session/Settings.kt:15-21) sent in clear in HELLO. A LAN attacker sniffs it from a Wi-Fi session. A tablet-local app cannot read MateBridge's prefs or sniff its loopback traffic, so for it this is hard.
- No session live at the time.

**Verdict:** Low/Medium availability and power issue (keep-awake, display churn). This agrees with verifier A.

## 4. SE1 D2D correction: CONFIRMED (Low; HarmonyOS behaviour unverified)

- client-android/app/build.gradle.kts:14 has `targetSdk = 31`. AndroidManifest.xml:17 has `android:allowBackup="false"` and no `dataExtractionRules` or `fullBackupContent` (grep is empty).
- Android 12 behaviour change for apps targeting API 31 or higher on Android 12+ devices: `allowBackup="false"` still disables **cloud** (Auto/Key-Value to Drive) backup, but **no longer disables device-to-device transfer**. Excluding D2D requires `android:dataExtractionRules` with a `<device-transfer>` section, an attribute that only takes effect for apps targeting 31+.
- So the prior wording is right: with targetSdk 31, `allowBackup=false` disables cloud backup only.
- **Impact:**
  - The Keystore-wrapped pair keys do not unwrap on the new device, so the result is KEY_MISSING.
  - The cleartext `device_id` and the settings would migrate. The new device then presents the same device_id, so the Mac answers PAIRED, which also triggers A1's pre-proof `sessionStarted` once.
  - Whether HarmonyOS 4.3 (Huawei Phone Clone) uses AOSP D2D semantics is unknown.

## Summary

| Item | Verdict | Key qualifier |
|---|---|---|
| H01 overwrite + display-only SAS + fake ACCEPTED opens input/clipboard both ways/FILES_INFO | CONFIRMED | Different-host_id auto-capture works on the Wi-Fi path when the tablet is Searching/Disconnected; ignored while Connected/Connecting. No picker, nothing on the Mac. |
| Local app on 127.0.0.1:47001 gets the DAV token | CONFIRMED (via H01 only) | AUTO's start-up probe is not cable-gated. The token is sealed, but in PAIRING the host is unauthenticated. With a real fix to H01 it is closed. |
| A1 pre-proof PAIRED activation | CONFIRMED | Resource/power/DoS only: virtual display, wake, display-sleep hold. No input/video/data. |
| SE1 D2D | CONFIRMED | Low; keys stay safe, device_id migrates. |
| New side finding | — | A migration candidate is promoted on a **plaintext** PAIRED/ACCEPTED ack (SessionMachine.kt:463/492-511). A squatter knowing host_id can pull a live Wi-Fi session onto 127.0.0.1:47001 (DoS only). The WI-1 fix should also gate promotion on the first authenticated host record. |
