---
id: T-155
title: Flag a replaced orphan approval request on the Mac
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-152]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeApp/ApprovalPanel.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - host-mac/Tests/MateBridgeCoreTests/Crypto/SessionCryptoTests.swift
  - backlog/tasks/T-155-host-orphan-approval-guard.md
---

## Amaç

In the Parsec flow the user sees the pairing code on the tablet, leaves for Parsec, and approves on the Mac a request whose connection already dropped (the "orphan" window, 2 min). Any device on the LAN that sends a HELLO with another `device_id` in that window silently replaces the dialog with its own request, its own code and a name it chose. The code comparison still protects, but only if the user compares again. This card keeps the new request (blocking it would be a DoS) but makes the swap visible: the panel says it is a **different** device and shows a short fingerprint, so a returning user does not click "İzin ver" out of habit.

Source: external architecture review 2026-10-03 (M05, approval surface); verification: docs/reviews/2026-10-03/verify-A-security.md (additional issue A6, M05 correction 3).

## Bağlam

- **Evidence (HEAD a30c769):**
  - `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift:683-687`: a new PAIRING request cancels an open orphan window (`orphan = nil`, `.cancelApproval(o.id)`, comment "A new request replaces a window left open by an earlier one (its stored key is dropped)") and then emits `.requestApproval(id, deviceID:, deviceName:, code:)` (:688). Nothing records that a replacement happened. The orphan is created in `end(…, orphaning: true)` (:776-781) with the `deviceID`.
  - The action reaches `SessionServer.swift:1475-1479`, which builds `ApprovalRequest(id:, deviceName:, code:)` (struct at `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift:169-175`) and calls `handlers.approvalRequested`. `host-mac/Sources/MateBridgeApp/main.swift:325-335` `askApproval` dismisses the old panel and builds `ApprovalPanel(requestID:, deviceName:, code:)` (`host-mac/Sources/MateBridgeApp/ApprovalPanel.swift:12-46`; it already has a `notice` line, :10/:34-36, used by `markDisconnected` :56-58).
  - The flag therefore has to travel through all four layers; that is why `SessionServer.swift` and `main.swift` are in `files:` in addition to the manifest's list.
  - Adding an associated value to `.requestApproval` changes the case arity: `host-mac/Tests/MateBridgeCoreTests/Crypto/SessionCryptoTests.swift:181` matches `.requestApproval(_, _, _, let c)` and stops compiling, hence that file is in `files:` (pattern update only).
  - A short device fingerprint already exists: `DeviceID.shortHex` (first 4 bytes, `host-mac/Sources/MateBridgeCore/Video/StreamPrefsStore.swift:52`), already logged as `device=` in `stream_session`.
- **Rules:**
  - The new request carries `replaced: none | sameDevice | otherDevice` (name may be refined).
  - Replacement by a **different** `device_id` (`otherDevice`) → the panel shows "Bu, önceki istekten FARKLI bir cihaz" plus the fingerprint, in the warning colour.
  - Replacement by the **same** `device_id` (`sameDevice`: the real tablet coming back before approval, e.g. after "Yeniden eşleş" in T-151) → the code changes and the panel shows a neutral notice "Kod değişti — tabletteki kodla yeniden karşılaştır" (no warning colour). After T-150 the tablet's automatic reconnect no longer re-rolls the code, but a user-initiated one still does.
  - Never block or delay the new request.
  - Note: `device_id` is client-chosen, so a spoofer can copy the real tablet's id (it is clear in HELLO); then only the changed code protects. After T-150/T-151 the tablet shows its stored code on return, so the user can still compare.
- **Logs:** `approval_pending replaced=none|same|other` (no device name, no code). `docs/LOGGING.md` addition under *Açık sorular*.
- **User decision pending (manifest §5 Q3):** whether to keep the orphan flow at all. This card assumes it stays.
- **Serialize with:** T-171 (same file `SessionMachine.swift`; chain T-152 → T-155 → T-171), T-163 and T-171 (same file `SessionServer.swift`; chain T-163 → T-171 → T-186 → …), T-145 and T-167 (same file `main.swift`; chain T-145 → T-167 → T-189 → T-192), T-196 (same file `SessionCryptoTests.swift`: its `files:` lists all of `host-mac/Tests/MateBridgeCoreTests/`).
- No wire change; `docs/PROTOCOL.md` is not affected.
- **Review:** security-related change: the orchestrator runs `./scripts/codex-review.sh`.

## Kapsam dışı

- Removing the orphan flow; a host "pairing mode" window; rate-limiting approval requests; client changes.

## Kabul kriterleri

- [ ] [XCTest] With an orphan window open for device A, a PAIRING HELLO from device B emits `.cancelApproval(orphan)` and a `.requestApproval` with `replaced == otherDevice` (and B's fingerprint available to the caller); the request is not blocked.
- [ ] [XCTest] The same with device A's own `device_id`: `replaced == sameDevice`; the request is not blocked.
- [ ] [XCTest] With no orphan window: `replaced == none`; existing orphan and pairing tests (e.g. `PairingOrphanApprovalTests`, `SessionCryptoTests`) pass, updated only for the new associated value.
- [ ] The panel shows "Bu, önceki istekten FARKLI bir cihaz" and the short fingerprint for `otherDevice`, the neutral "Kod değişti — tabletteki kodla yeniden karşılaştır" for `sameDevice`, and nothing extra for `none`.
- [ ] No device name or code is logged; the `approval_pending` line carries only `replaced=none|same|other`.
- [ ] [device] (T-157 step 11) With an orphan window open from the tablet, launch the APK on a second Android device (phone, sideloaded) → the panel shows "FARKLI bir cihaz" and the fingerprint. If no second device is available: "not run" in T-157, and the XCTests are the evidence.
- [ ] The orchestrator ran `./scripts/codex-review.sh` and its findings are resolved or recorded.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **Core (`SessionMachine.swift`):** new `public enum ApprovalReplacement { none, sameDevice, otherDevice }` with `logValue` (`none|same|other`). `.requestApproval` gets a fifth associated value `replaced:`. In `continueHello`'s PAIRING branch the open orphan (if any) is compared with `hello.deviceID` before it is cancelled; the request is emitted unchanged otherwise (no block, no delay). `approval_pending` gets `fields: "replaced=…"` (no name, no code).
2. **Tests:** new `Session/ApprovalReplacementTests.swift` (orphan A + B → `otherDevice`, `.cancelApproval(A)` before the request, B's `shortHex` available via `deviceID`; orphan A + A → `sameDevice`; no orphan → `none`; log fields). Pattern updates only in `SessionCryptoTests.swift` and existing `Session/` tests that match the 4-ary case.
3. **Host (`SessionServer.swift`):** `ApprovalRequest` gets `replaced: ApprovalReplacement` and `deviceFingerprint: String` (`DeviceID.shortHex`); filled from the action. Keychain-busy re-show keeps them (same stored request).
4. **App (`main.swift`, `ApprovalPanel.swift`):** panel init takes `replaced` + `fingerprint`; a separate label (so `setNotice` for disconnected/keychain does not overwrite it): `otherDevice` → "Bu, önceki istekten FARKLI bir cihaz" + "Cihaz parmak izi: xxxxxxxx" in `systemRed` (warning colour); `sameDevice` → neutral "Kod değişti — tabletteki kodla yeniden karşılaştır" (`secondaryLabelColor`); `none` → hidden.
5. `./scripts/check.sh`, commit, Handoff.

Risks: case arity change breaks every `case .requestApproval` pattern (compile-time, all in `files:`). The fingerprint is not a secret but is not logged by the app either (only `replaced=`).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:** `c2853004f33b8ccea3ac303a5101ba0af408a0ec` (implementation; plan `9430b52`); Codex review fix `ce1d37cc12ac46515a7fa67ba563c652ff4f4d12`; Handoff updates in the commits that follow. Branch `task/T-155-host-orphan-approval-guard`.
- **Codex review (--high) P2, fixed in `ce1d37c`:** when B, after taking over the window, left and came back with its own `device_id`, the request became `sameDevice` and the red warning turned into the neutral notice. Now `Pairing.replaced` is carried into the orphan as `Orphan.otherDeviceSeen`. Once set, every later replacement in the same window (B→B, or the real tablet returning, B→A) yields `otherDevice` until the user decides or the window expires; after that a new request is `none` again. New tests: `theDifferentDeviceFlagIsStickyAcrossItsOwnReconnects` (A→B→B→B, through both close and BYE), `theRealTabletReturningAfterATakeoverIsStillFlaggedAsDifferent`, `theSameDeviceRepeatedlyStaysSame` (A→A→A stays `sameDevice`), `theStickyFlagEndsWithTheDecisionOrTheWindow`. The request is still never blocked.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Session/SessionMachine.swift`: new `ApprovalReplacement { none, sameDevice, otherDevice }` + `logValue` (`none|same|other`); `.requestApproval(…, code:, replaced:)`; the PAIRING branch of `continueHello` compares the open orphan's `deviceID` with the HELLO's before cancelling it; `approval_pending` now has `fields: "replaced=…"`.
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`: `ApprovalRequest` gets `replaced` and `deviceFingerprint` (`DeviceID.shortHex`). The Keychain-busy re-show reuses the stored request, so the warning survives it.
  - `host-mac/Sources/MateBridgeApp/main.swift`: passes both into the panel (logs unchanged: `approval_shown conn=` only).
  - `host-mac/Sources/MateBridgeApp/ApprovalPanel.swift`: an extra label between "Tabletteki kodla aynı mı?" and the existing `notice` line. `otherDevice`: "Bu, önceki istekten FARKLI bir cihaz." + "Cihaz parmak izi: xxxxxxxx" in bold `systemRed`. `sameDevice`: "Kod değişti — tabletteki kodla yeniden karşılaştır." in `secondaryLabelColor` (neutral). `none`: nothing. It is a separate label, so `markDisconnected`/Keychain `setNotice` cannot overwrite it.
  - Tests: new `host-mac/Tests/MateBridgeCoreTests/Session/ApprovalReplacementTests.swift` (none / other with fingerprint `02020202`, cancel-before-request order, ack `pendingApproval` i.e. not blocked / same / expired or decided orphan → none / no name, code or fingerprint in any log field / logValue). Pattern-only updates (one extra `_`/`.none`) in `SessionCryptoTests.swift`, `PairedProofFirstTests.swift`, `PairingOrphanApprovalTests.swift`, `SessionMachineTests.swift`.
- **Varsayımlar:** "Warning colour" = `systemRed` bold, which sets it apart from the existing orange `notice`. The fingerprint is `DeviceID.shortHex` (first 4 bytes); it is shown in the panel but not logged by the app. A new orphan replacing an older orphan inside `end(orphaning:)` is not flagged, since a request always cancels the orphan first and so that path does not occur in practice. The orphan flow stays (manifest §5 Q3 is still open).
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - The panel itself is not shown (no GUI on the Mac in this task). On the device: with an orphan window from the tablet, a HELLO from a second Android device should show the red "FARKLI bir cihaz" text + fingerprint (T-157 step 11). If there is no second device, the XCTests are the evidence.
  - The same tablet with "Yeniden eşleş" (T-151) inside the orphan window should show the grey "Kod değişti …" line, and the code should match the tablet's new code.
  - Panel layout: the panel's height should fit the extra line (`fittingSize`); check it visually.
  - Not run: `./scripts/codex-review.sh` (orchestrator).
- **Açık sorular:**
  - `docs/LOGGING.md` (not in `files:`): `approval_pending` now carries `replaced=none|same|other` (none: no window was open; same: replaced the orphaned window of the same `device_id`; other: of a different `device_id`). The orchestrator should add this line to the event table.
