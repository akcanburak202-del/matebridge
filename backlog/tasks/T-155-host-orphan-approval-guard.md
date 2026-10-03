---
id: T-155
title: Flag a replaced orphan approval request on the Mac
status: todo
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

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
