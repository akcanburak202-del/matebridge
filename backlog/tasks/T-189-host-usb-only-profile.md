---
id: T-189
title: Add a "Yalnız USB" network profile
status: review
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0027]
files:
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift
  - host-mac/Sources/MateBridgeCore/Session/NetworkProfile.swift
  - host-mac/Sources/MateBridgeHost/Session/UserDefaultsStreamPrefsStore.swift
  - host-mac/Sources/MateBridgeApp/main.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - backlog/tasks/T-189-host-usb-only-profile.md
---

## Amaç

The host listens for control and video connections on every interface and always advertises itself over Bonjour, although the daily path is USB (`adb reverse`), which only needs loopback. An optional "Yalnız USB" profile closes the LAN listening and pairing surface: listeners bind to loopback only, Bonjour is not advertised, and non-loopback peers are refused. The default stays "USB + Wi-Fi".

Source: external architecture review 2026-10-03 (M05, D9); verification: docs/reviews/2026-10-03/verify-A-security.md (WI-5).
Decision 0027 must be accepted by the user before work starts (manifest §5 Q6: does the user want this mode at all?).

## Bağlam

**Evidence at HEAD:**
- `BsdTcpListener` binds `[::]` with `IPV6_V6ONLY=0` by default (`BsdTcpSocket.swift:72-141`; `BindAddress.any` at :91). The loopback cases `.loopbackV6` (`::1`, :93) and `.loopbackV4Mapped` (`::ffff:127.0.0.1`, :95) already exist, but only tests use them (`ControlSocketTests.swift:327` uses `.loopbackV4Mapped`).
- Production listeners use the default `.any`: video at `SessionServer.swift:639`, control at `SessionServer.swift:1031`. Bonjour for the bsd control listener: `bonjour: BonjourAdvertiser?` (`SessionServer.swift:227-228`), started by `startBonjour(for:)` (`:1079`) right before `controlListenerReady` (`:1060-1071`).
- `bsd` is already the default for both sockets (`SessionServer.swift:178`, `:314-317`), so the `nw` listeners (`SessionServer.swift:600`, `:987-990`, `listener.service = bonjourService()` at `:571`/`:989`) are reachable only through the debug knobs `MATEBRIDGE_CONTROL_SOCKET=nw` / `MATEBRIDGE_VIDEO_SOCKET=nw`. T-186 removes them, but this card does not wait for it (see *Plan hints*). Re-check all line numbers if T-186 has merged first.
- Bonjour has three start paths, all through `startBonjour(for:)` (`:1079`): the listener start (`:1062`), the TXT republish from `republishTxt` (`:579`, the T-128 `wol=` update), and the retry in `bonjourFailed` (`:1114`).
- USB sessions arrive from a loopback peer. `SessionServer.transport(of:)` (`SessionServer.swift:1635-1646`) calls `SessionTransport.classify(peerHost:)` (`host-mac/Sources/MateBridgeCore/Usb/UsbTunnelPlanner.swift:107-112`), which treats `::1`, `127.0.0.1`, `::ffff:127.0.0.1` and `localhost` as USB. A loopback-only profile therefore works with `adb reverse`.
- There is no USB-only or interface setting anywhere in the host today.

**Failure scenario (why):** while the tablet is on USB every day, any LAN device can still reach 47001/47002, send HELLO, raise the approval dialog, and find the host through Bonjour (see T-155 for approval fatigue). In "Yalnız USB" mode none of this is reachable from the LAN.

**What the mode does (decision 0027):**
- The control and video listeners bind loopback only.
- No Bonjour advertisement, so no TXT `wol=` record either (T-128).
- Non-loopback peers are refused at accept on both listeners (defence in depth; with a loopback bind they cannot connect anyway).
- Wi-Fi fallback and the wake flows (T-133/T-134) are not available in this mode. The tablet shows the existing USB hint.
- Default: "USB + Wi-Fi", which is today's behaviour unchanged.

**Plan hints:**
- Put the pure part in a new Core type `NetworkProfile` (`usbOnly` / `all`): the bind address per profile, whether Bonjour runs, and `admits(peerHost:)` built on `SessionTransport.classify`. Then it can be tested in XCTest (`MateBridgeHost` has no test target, `host-mac/Package.swift:18`). Store the preference next to the existing `usbModeEnabled` key in `main.swift` (:40, :189-191). Use `UserDefaultsStreamPrefsStore.swift` only if a store type there fits better, and justify it in Plan.
- **`nw` knobs vs. T-186:** do not wait for T-186. If T-186 has not merged when this card starts, "Yalnız USB" forces the `bsd` listeners: it ignores `MATEBRIDGE_CONTROL_SOCKET=nw` / `MATEBRIDGE_VIDEO_SOCKET=nw` and logs that once. If T-186 has merged, the `nw` path no longer exists and nothing needs forcing.
- **Bonjour gate:** gate inside `startBonjour(for:)` itself, so that neither the TXT republish (`:579`) nor the retry (`:1114`) can advertise in USB-only mode.
- **Bind address:** one dual-stack socket can bind only one address. `.loopbackV4Mapped` accepts IPv4 127.0.0.1 only, and `.loopbackV6` accepts ::1 only. Find out which address the Mac's adb server uses for the `adb reverse` target (`scripts/usb-mode.sh:62`; usually 127.0.0.1). Bind that address, or both with two listeners per port, and justify the choice in Plan. The port fallback (47001/47002 busy → system port) must keep working.
- **Relation to the existing "USB modu" toggle** (`main.swift:37, 186, 227-232`; the `adb reverse` watcher, default on): "Yalnız USB" with "USB modu" off leaves no working transport. Either force or disable the USB modu toggle while Yalnız USB is on, or show a warning line. Decide in Plan.
- **Switching the mode:** restart both listeners (and start/stop Bonjour) only while no session is live. If a session is live, either defer the switch until it ends, or end a Wi-Fi session first. A live USB session must not be cut. Decide and justify in Plan.
- Log the active profile once per listen, e.g. a `profile=usb_only|all` field on the `listening` line (`SessionServer.swift:1068-1071`). Update `docs/LOGGING.md` through *Açık sorular* (orchestrator).
- **Serialize with T-145 and T-167 (same file `host-mac/Sources/MateBridgeApp/main.swift`).** The chain is T-145 → T-167 → T-189 → T-192.
- **Serialize with T-186 (`SessionServer.swift`).** T-186 is not a dependency: whichever of the two merges second rebases onto the other. Also serialize with T-163, T-171 and T-196 on the same file (chain T-163 → T-171 → T-186/T-189 → T-196).
- **PROTOCOL.md (orchestrator only):** §3 step 1 "Keşif" gets one prose sentence saying that Bonjour may be absent in "Yalnız USB" mode. No bytes or fixtures change. Implementers do not edit PROTOCOL.md.
- **Risk:** Codex review is required (security, CLAUDE.md).

## Kapsam dışı

- Per-interface selection and automatic LAN profiles.
- Any client change. The tablet's AUTO mode simply finds no Wi-Fi host.
- The tablet files `adb forward` path (`TabletFilesBridge`), which is unaffected.

## Kabul kriterleri

- [ ] [XCTest] A listener created with the USB-only bind address refuses a connect to a non-loopback local address. If the machine has no non-loopback IPv4 address, the test skips with a message; it never fails spuriously.
- [ ] [XCTest] `NetworkProfile.admits(peerHost:)` accepts `127.0.0.1`, `::1`, `::ffff:127.0.0.1` (also with a `%scope` suffix) and rejects LAN IPv4/IPv6 peers in USB-only mode. In "USB + Wi-Fi" mode it accepts all of them.
- [ ] [XCTest] The profile preference parses and round-trips. A missing or unknown value means "USB + Wi-Fi".
- [ ] [XCTest] The pure switch decision: no live session → restart now; live USB session → deferred, never cut; live Wi-Fi session → as decided in Plan.
- [ ] [XCTest] In USB-only mode the effective socket kind is `bsd` for both listeners, even when the `nw` knob is set (only while the `nw` path still exists).
- [ ] [device] The menu has a "Yalnız USB" toggle whose state persists across relaunches. Its interaction with "USB modu" works as decided in Plan.
- [ ] [device] Switching the mode restarts the listeners cleanly while no session is live. With a live session it behaves as decided in Plan, and a USB session is never cut.
- [ ] [device] In USB-only mode, `lsof -iTCP -sTCP:LISTEN -P` shows 47001/47002 only on loopback addresses (no `*:47001`/`*:47002`), `dns-sd -B _matebridge._tcp` shows nothing (also after a `wol=` TXT change), and a USB session (video, pen, keyboard, audio, files) works.
- [ ] [device] Back in "USB + Wi-Fi": Bonjour is visible again, a Wi-Fi session connects, and the TXT `wol=` record is present.
- [ ] Codex review (security) has no open findings.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

T-186 merged before this card: the `nw` listeners no longer exist, so there is nothing to force to `bsd` (that XCTest criterion is N/A).

1. **Core `NetworkProfile`** (`MateBridgeCore/Session/NetworkProfile.swift`): `enum NetworkProfile { case all, usbOnly }`, stored as the strings `"all"` / `"usb_only"` under UserDefaults key `networkProfile`. A missing or unknown value parses as `.all`. Per profile it gives:
   - `bindAddress`: `.any` / `.loopbackV4Mapped`;
   - `advertisesBonjour`;
   - `admits(peerHost:)`, built on `SessionTransport.classify`; a nil peer is refused in usb-only mode;
   - `effectiveUsbMode(stored:)` and `allowsUsbModeToggle`.

   It also has a pure switch decision, `NetworkProfileSwitch.decide(current:requested:activity:)`, where activity is `idle | pendingApproval | active(SessionTransport)`. The result is `unchanged | restartNow | deferred`.
2. **Bind address = IPv4 loopback only (`::ffff:127.0.0.1`, one dual-stack socket per port, as today).** The Mac adb server opens the `adb reverse` target as a loopback client and tries IPv4 127.0.0.1 first; ::1 is only a fallback when IPv4 fails. `ControlSocketTests.testIPv4LoopbackSessionIsClassifiedUsb` already models this. One listener per port keeps `ListenerPortPlan` and the port fallback unchanged. Two listeners per port would add a second bind that has to share the fallback port, for no gain. Device check: a USB session works with `lsof` showing only `127.0.0.1:47001/47002`.
3. **SessionServer:**
   - `init(networkProfile:)`, plus `setNetworkProfile(_:)` (session queue).
   - Both listeners bind `profile.bindAddress`.
   - `acceptControl`/`acceptVideo` refuse a non-admitted peer before `start` (`ev=connection_refused reason=profile`).
   - `startBonjour(for:)` is gated: in usb-only mode it cancels any record and returns, which covers the listener start, the TXT republish and the retry paths.
   - The `listening` line gets `profile=all|usb_only`.
   - New handler `networkProfileChanged(applied, pending)` for the menu.
4. **Switch decision:**
   - No session (idle, or only unauthenticated or approval-pending connections): restart now. `machine.shutdown()` closes the half-open connections and cancels a pending approval, so a LAN peer cannot keep a pairing alive into usb-only mode. No session exists to cut. Then the listeners are cancelled and restarted with the new profile. If a failure restart is already scheduled, only the profile is set, and the scheduled restart uses it.
   - **Any live session (USB or Wi-Fi): deferred** until the session ends. The switch is applied automatically when the server becomes session-free, and the menu shows it as pending. A USB session is never cut. A Wi-Fi session is not ended either: on this Mac mini the tablet is the only screen, and the click comes from that screen. Ending the Wi-Fi session at once (with no cable attached) would cut the user's only display while the new mode refuses Wi-Fi reconnects. Deferring keeps the screen until the user leaves the session.
5. **Menu (`main.swift`):**
   - A "Yalnız USB" toggle next to "USB modu" persists `networkProfile`.
   - While it is on, the `adb reverse` watcher is forced on (`effectiveUsbMode`). The "USB modu" item shows on but is disabled; the stored `usbModeEnabled` stays untouched, so turning Yalnız USB off restores the user's own choice.
   - A status line is shown whenever usb-only mode is active or a switch is pending: "Ağ: yalnız USB (Wi-Fi ve Bonjour kapalı)" or "… oturum bitince uygulanacak". The default mode shows no extra line (unchanged UI).
6. **Tests (`Tests/MateBridgeCoreTests/Session/NetworkProfileTests.swift`):**
   - parse and round-trip;
   - `admits` covering loopback forms with `%scope`, LAN v4/v6 and nil;
   - the switch decision table;
   - USB modu forcing;
   - real sockets: the usb-only bind address accepts 127.0.0.1 and refuses a connect to the machine's own non-loopback IPv4. The test skips when no such address exists, or when an `.any` control listener is not reachable on it either.
7. `UserDefaultsStreamPrefsStore.swift` is not needed: it stores per-device stream prefs, and the profile is an app-level bool-like key next to `usbModeEnabled`.

Risks: the adb loopback family (verified on device by `lsof` plus a USB session), and the user forgetting the mode (mitigated by the menu line).

## Handoff

- **Commit:** `7cbe255` (Codex P2 fixes) on top of `9fab1f9` (implementation); plan in `0de508e`.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Session/NetworkProfile.swift` (new: `NetworkProfile`, `NetworkActivity`, `NetworkProfileSwitch`, `NetworkProfileController`, `usbWatcherEnabled` / `usbModeToggleAllowed`);
  - `host-mac/Sources/MateBridgeCore/Session/BsdTcpSocket.swift` (`BindAddress` is now `Equatable`; `BsdTcpListener.cancel(onClosed:)` reports once the descriptor is closed);
  - `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`:
    - `init(networkProfile:)`, `setNetworkProfile(_:)`, `Handlers.networkProfileChanged`;
    - bind address per profile;
    - accept-time refusal `ev=connection_refused reason=profile`;
    - Bonjour gate in `startBonjour(for:)`;
    - `profile=` on `ev=listening`;
    - `ev=network_profile profile=… from=… action=restart|deferred`;
  - `host-mac/Sources/MateBridgeApp/main.swift`: "Yalnız USB (Wi-Fi kapalı)" toggle, a profile line, and USB modu locked on in the mode;
  - `host-mac/Tests/MateBridgeCoreTests/Session/NetworkProfileTests.swift` (20 tests; on this machine the real-socket test ran instead of skipping).
  - `UserDefaultsStreamPrefsStore.swift` was not touched (see Plan, step 7).
- **Varsayımlar:**
  - T-186 had merged, so `nw` forcing is N/A. The "effective socket kind is bsd" XCTest criterion does not apply because only `bsd` exists.
  - The Mac's adb server connects the `adb reverse` target over IPv4 127.0.0.1 first, so binding `::ffff:127.0.0.1` alone is enough (`::1` is not bound).
  - A live session of either transport defers the switch. Idle, or approval-pending, restarts at once and closes half-open connections and the pending approval.
  - UserDefaults key `networkProfile`, values `all` / `usb_only`; anything else means "USB + Wi-Fi".
  - **Codex P2 #1 fix:** the `adb reverse` watcher (and the shown "USB modu" state and its lock) follows the stored USB modu choice OR the applied profile OR the requested profile (`NetworkProfile.usbWatcherEnabled`).
    - Leaving USB-only keeps the tunnels until the deferred switch actually takes effect (`networkProfileChanged` reports the applied profile).
    - Entering USB-only brings the tunnels up at once. That is earlier than "applied only", but adding tunnels never harms a live session, and the mode is never left without them.
  - **Codex P2 #2 fix:** a profile restart is two steps (`NetworkProfileController`).
    - First the old listeners are cancelled with `cancel(onClosed:)`. The new ones bind only after both descriptors have closed (DispatchGroup notify on the session queue).
    - Requests arriving meanwhile are coalesced, and the restart starts the latest request once.
    - A `port_fallback` during a profile restart is logged at **error** level with `after=profile_switch`.
  - `./scripts/check.sh` ALL OK after the fixes.
  - `./scripts/check.sh` ALL OK.
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - The menu: the "Yalnız USB" toggle persists across relaunches. While it is on, "USB modu" shows on and is disabled, and turning the mode off restores the earlier USB modu choice. The profile line text reads correctly.
  - In USB-only mode, `lsof -iTCP -sTCP:LISTEN -P` shows only `127.0.0.1` (or `[::ffff:127.0.0.1]`) for 47001/47002, with no `*:`.
  - In USB-only mode, `dns-sd -B _matebridge._tcp` is empty, including after a `wol=` change (for example toggling Wi-Fi).
  - A USB session works in USB-only mode: video, pen, keyboard, audio and files. **The adb loopback family assumption is the main risk.**
  - Switching with no session: `ev=network_profile action=restart` followed by a new `ev=listening … profile=`.
  - Switching with a live USB or Wi-Fi session: `action=deferred`, the menu line "… oturum bitince uygulanacak", the session is not cut, and the switch applies after the session ends.
  - Codex scenario: with USB modu stored off, turn Yalnız USB on and start a USB session, then turn Yalnız USB off. `adb reverse --list` must still show 47001/47002, and a STREAM_PREFS change (which reconnects video) must not freeze the screen. The tunnels go only after the session ends.
  - Rapid toggling (Yalnız USB on/off/on with no session): exactly one `listening` line per completed restart, still on 47001/47002, and no `port_fallback`.
  - Back in "USB + Wi-Fi": Bonjour is visible with TXT `wol=`, and a Wi-Fi session connects.
  - A LAN connect attempt in USB-only mode is refused (the bind refuses it; `reason=profile` is unreachable with a loopback bind, defence in depth).
  - Codex review (security) is still pending.
- **Açık sorular:**
  - `docs/LOGGING.md` (orchestrator):
    - `ev=listening` gains `profile=all|usb_only`;
    - `ev=connection_refused` gains `reason=profile` plus a `profile=` field;
    - new `ev=network_profile profile=all|usb_only from=all|usb_only action=restart|deferred` (component `session`);
    - `ev=port_fallback` gets `after=profile_switch`, at error level, when it happens during a profile restart.
  - `docs/PROTOCOL.md` §3 step 1 (orchestrator): the planned note that Bonjour may be absent in "Yalnız USB" mode.
  - Decision note for the orchestrator: a live **Wi-Fi** session is deferred, not ended (reason in Plan, step 4: the tablet is the only screen). If ending it is preferred, flip the `.active(.network)` branch in `NetworkProfileSwitch.decide` and its test.
  - While a switch to USB-only is deferred, the LAN listeners and Bonjour stay up until the session ends. The menu line shows this.
  - T-192 (settings reset) should also clear the `networkProfile` key.
