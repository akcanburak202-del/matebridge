---
id: T-178
title: Use a conservative default bitrate on Wi-Fi (host only)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-127]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Video/TransportBitrate.swift
  - host-mac/Sources/MateBridgeCore/Video/StreamPrefsPolicy.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoSettings.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderKnobs.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/NOTES.md
  - backlog/tasks/T-178-host-wifi-default-bitrate.md
---

## Amaç

On Wi-Fi, the same mode defaults as on USB (30 Mbps at 60 fps, 60 Mbps at 120 fps, up to 80 Mbps) produce video bursts. These bursts raise control srtt from 20 ms to 60–100 ms and cause audio underruns. The cheapest lever is a fixed, more conservative default bitrate on Wi-Fi sessions, applied by the host alone, with no protocol change. The user's explicit bitrate choice still wins. If T-127 shows a fixed profile is enough, Wi-Fi gets better without any congestion-control code.

Source: external architecture review 2026-10-03 (H03, D6, D8); verification: docs/reviews/2026-10-03/verify-F-network.md (F-7, host-only variant).
Decision 0023 must be accepted by the user before work starts.
Gated: start only after T-127 has recorded its result in docs/NOTES.md with the 0023 branch "fixed profile suffices" and a chosen Wi-Fi value. If T-127 says "go adaptive", this card is still the first step only if the orchestrator says so. Otherwise it waits behind T-195/T-196.

## Bağlam

**Evidence at HEAD (a30c769):**
- Mode defaults come from `defaultBitrateKbps(fps:scalePermille:)` (`host-mac/Sources/MateBridgeCore/Video/StreamPrefsPolicy.swift:21-27`): 30 Mbps × fps/60 × scale², clamped to 20–80 Mbps. USB and Wi-Fi use the same default.
- `applying(_ prefs:)` (`StreamPrefsPolicy.swift:44-54`) applies the bitrate priority of decision 0013: env override > the user's `STREAM_PREFS.bitrate_kbps` (clamped) > the mode default.
- The only Wi-Fi-specific value today is the developer env `MATEBRIDGE_WIFI_BITRATE_KBPS` (`TransportBitrate.swift:20-28`, T-088). It is applied as an *override*, so it beats the user's choice.
- The transport is known when a session starts: `StreamCoordinator.swift:187` calls `applyingTransportKnobs` with `.usb` (loopback) or `.network`. For the first `STREAM_CONFIG` (`streamConfig(for:)`, `:194-197`) the transport is nil. The tablet ignores that config's bitrate (comment at `:179-180`), so this is fine. Keep it that way and say so in the test.
- The user's bitrate preference is stored per device, not per transport (`StreamPrefsStore.swift`). The tablet panel offers "Otomatik / 15 / 30 / 60 / 100 Mbps" (decision 0013). "Otomatik" sends `0`, which means the host default. So this card changes only what "Otomatik" means on Wi-Fi.
- `bitrate_source=` is logged at `stream_session` and on reconfigure (`StreamCoordinator.swift:326`, `:387`). The values are computed in `VideoSettings.bitrateSource` (`EncoderKnobs.swift:196-205`) from `BitrateSource` (`TransportBitrate.swift:4-13`).

**Design hints:**
- A Wi-Fi mode default must survive later `STREAM_PREFS` with `bitrate_kbps = 0`. That needs stored state in `VideoSettings`, because Swift extensions cannot add stored properties. Add one stored field in `VideoSettings.swift`, for example a transport-derived default cap, or a `transport` value read by `defaultBitrateKbps`. That file is in `files:` for this reason only.
- Add a `bitrate_source=wifi_default` value (`BitrateSource`, `bitrateSource` in `EncoderKnobs.swift`), so that logs and T-127 re-runs are labelled correctly.
- Suggested rule: on `.network`, mode default = `min(modeDefault, wifiDefaultKbps)`. A non-zero user value and the env overrides keep their priority. `MATEBRIDGE_WIFI_BITRATE_KBPS` stays an env override above the user, as today.
- **First-ever connection:** with no stored prefs, `VideoSettings.initialSettings` returns `defaults` (= `base`) unchanged (`StreamPrefsStore.swift:43-47`). `base.bitrateKbps` is the `tabletDefault` 30 000 (`VideoSettings.swift:30-32`), and `applying(_:)` is never called. A rule implemented only in `applying`/`defaultBitrateKbps` would leave that session at the USB default. So `applyingTransportKnobs(.network)` (`TransportBitrate.swift:20-28`; today it returns early unless the Wi-Fi env knob is set) also applies the Wi-Fi cap to `self.bitrateKbps` when there is no override.
- **Label meaning:** `bitrate_source=wifi_default` means "the Wi-Fi session default rule decided the bitrate" (a `.network` session with no user value and no env override). It is logged even when `wifiDefault ≥ modeDefault` and the cap does not bind, because the log must say which rule was in effect.
- The Wi-Fi value is the one T-127 recorded. Write it as a named constant whose doc comment cites the NOTES entry.
- 0023 amends decision 0013 (Wi-Fi default). The orchestrator updates 0013 and PLAN.md:74/:126; implementers do not.
- Rejected variant: a separate Wi-Fi field in `STREAM_PREFS`. That is a wire change and is rejected in 0023.

**Serialization:** `VideoSettings.swift` and `EncoderKnobs.swift` are also edited by T-204 (retires `MATEBRIDGE_FRAME_DELAY` and others; the encoder half of the former T-186) and T-177 (step knob in `EncoderKnobs.swift`). Serialize with T-177 and T-204 (same files).

Wire: none. No PROTOCOL.md change.

## Kapsam dışı

- Live or adaptive bitrate (T-177, T-195, T-196).
- A tablet-side per-transport bitrate setting or panel change.
- Changing USB defaults or the 0013 priority order.

## Kabul kriterleri

- [ ] [XCTest] On `transport: .network` with no user bitrate and no env override, the session bitrate is the Wi-Fi default (`min(modeDefault, wifiDefault)`) for every stream mode (Netlik 60, Akıcı 120, Performans, Oyun 120, Oyun 60), and `bitrateSource == "wifi_default"`, including a mode whose default is already ≤ the Wi-Fi value (the cap does not bind).
- [ ] [XCTest] The Wi-Fi default survives a later `STREAM_PREFS` with `bitrate_kbps = 0` and a mode change on the same Wi-Fi session.
- [ ] [XCTest] Priority unchanged (decision 0013): a non-zero user `bitrate_kbps` wins over the Wi-Fi default; `MATEBRIDGE_BITRATE_KBPS` and `MATEBRIDGE_WIFI_BITRATE_KBPS` win over both. The existing `BitratePrefsTests` pass.
- [ ] [XCTest] First-ever connection: `initialSettings(defaults: base(.network), stored: nil)` yields the Wi-Fi default with `bitrate_source=wifi_default`.
- [ ] [XCTest] `transport: .usb` and `transport: nil` (first `STREAM_CONFIG`) are unchanged.
- [ ] [device] Re-run the T-127 topology-3 row (both on Wi-Fi, same workload, ≥3 runs) with the panel on "Otomatik". Record audio underruns, control srtt p95 and client capture→decode p95 against the T-127 budgets in docs/NOTES.md, together with the host and APK commit SHAs. `stream_session` shows `bitrate_source=wifi_default`.
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
