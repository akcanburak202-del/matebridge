---
id: T-192
title: Add "Ayarları sıfırla" to the menu (approvals kept)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-167, T-189]
decisions: []
files:
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Sources/MateBridgeHost/Session/UserDefaultsStreamPrefsStore.swift
  - host-mac/Sources/MateBridgeCore/Video/StreamPrefsStore.swift
  - host-mac/Sources/MateBridgeCore/Session/HostSettingsReset.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - host-mac/Tests/MateBridgeCoreTests/Session/HostSettingsResetTests.swift
  - backlog/tasks/T-192-host-settings-reset.md
---

## Amaç

The host menu can forget approved devices, but it cannot restore its own settings to a known-good state. "Ayarları sıfırla" should reset the stored per-tablet stream modes, "USB modu", clipboard sharing, the "Yalnız USB" profile (T-189) and the display keep time (T-167) to their defaults. Approved devices and the Keychain identity stay untouched, so the tablet reconnects without a new approval. This is the host half of the known-good recovery path (D9).

Source: external architecture review 2026-10-03 (D9); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (RESET-H).

## Bağlam

**Evidence at HEAD:**
- The menu has only "Onaylı cihazları unut" (`main.swift:90`, handler `forgetDevices` at `:292-294`). It has no settings reset.
- Host settings in `UserDefaults.standard` (domain `dev.matebridge.host` for the bundled app):
  - `streamPrefsByDevice`: per-tablet `[fps, scale_permille, bitrate_kbps]` (`UserDefaultsStreamPrefsStore.swift:4-36`, key at :8);
  - `usbModeEnabled`, default true (`main.swift:40, 189-191`);
  - `clipboardSharingEnabled`, default true (`ClipboardBridge.swift:32`; `main.swift:193-195`);
  - after T-189, the network profile key; after T-167, the display keep-time key.
- **Keep:**
  - `loginItemFirstRunDone` (`LoginItem.swift:10, 41-43`); resetting it would re-register the login item on the next launch;
  - approvals in `~/Library/Application Support/MateBridge/approved-devices.json` (`ApprovedDeviceStore.swift:4-17`);
  - pair keys and host identity in the Keychain (`KeychainPairKeyStore.swift`).
- `StreamPrefsStoring` (`StreamPrefsStore.swift:5-8`) has only `load`/`save`, so `removeAll()` is new. `MateBridgeHost` has no test target (`host-mac/Package.swift:18`). Therefore the testable logic goes into Core: `InMemoryStreamPrefsStore.removeAll()`, plus a small `HostSettingsReset` that removes a given key list from an injected `UserDefaults`. The XCTest uses `UserDefaults(suiteName:)`. The app passes the key list, because `ClipboardBridge.defaultsKey` lives in `MateBridgeHost`.

**What the user sees after a reset:** the host's stored prefs only decide the **first** `STREAM_CONFIG` of a session. The tablet then sends its own `STREAM_PREFS` from its settings (the client queues STREAM_PREFS at ACCEPTED; verify-A2 l.13). So after a host reset:
- the next session logs `stream_session … from_stored=false` (`StreamCoordinator.swift:325`);
- it starts in the HELLO defaults;
- the tablet's choice is then applied (config 2, possibly one display recreate on 60↔120).
To get full defaults on both sides, use T-191 on the tablet as well. Say so in the menu item's confirmation text.

**Plan hints:**
- A confirmation alert ("Ayarları sıfırla? Onaylı cihazlar ve eşleşme korunur.") before acting.
- Apply live where it is cheap: `usbWatcher.setEnabled(true)`, `clipboard.setEnabled(true)`, menu states refreshed. For the network profile, use T-189's switch path and its rules for a live session. For the keep time, use T-167's setter (takes effect from now).
- Stored stream prefs are not applied to a live session; they affect the next connection only. `UserDefaultsStreamPrefsStore` reads `UserDefaults` on every `load` and keeps no cache. So removing the key from the app (a second store instance or `HostSettingsReset`) is enough, and `StreamCoordinator.swift` (which builds its own store at :116) needs no change.
- Log `ev=settings_reset` once, with no values.
- **Serialize with T-145 (same file `main.swift`).** The chain is T-145 → T-167 → T-189 → T-192; T-167 and T-189 are already `depends_on`.
- `HC/Session/HostSettingsReset.swift` and its test are additions to the manifest's file list, needed because `MateBridgeHost` cannot be unit-tested.

## Kapsam dışı

- Approvals, pair keys, the host identity and the login item (it has its own menu toggle).
- Tablet settings (T-191).
- Any change to default values.

## Kabul kriterleri

- [ ] [XCTest] `InMemoryStreamPrefsStore.removeAll()` empties the store: every `load` returns nil afterwards.
- [ ] [XCTest] `HostSettingsReset` on a suite `UserDefaults` removes exactly the given keys and leaves an unrelated key (standing in for `loginItemFirstRunDone`) untouched.
- [ ] `UserDefaultsStreamPrefsStore.removeAll()` removes the `streamPrefsByDevice` key.
- [ ] The menu item asks for confirmation. After a reset, "USB modu" and "Pano paylaşımı" show on, the network profile shows "USB + Wi-Fi" and the keep time shows its default.
- [ ] Exactly one `ev=settings_reset` line, with no values.
- [ ] [device] With the tablet in Netlik and a stored host entry: reset, then reconnect. The host logs `from_stored=false` for that session, then applies the tablet's STREAM_PREFS. The tablet reconnects with no approval prompt (approvals and Keychain kept), and `approved-devices.json` is unchanged.
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
