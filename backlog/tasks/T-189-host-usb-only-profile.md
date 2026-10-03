---
id: T-189
title: Add a "Yalnız USB" network profile
status: todo
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

_(Ajan kodlamadan önce doldurur: adımlar, dokunulacak dosyalar, riskler.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
