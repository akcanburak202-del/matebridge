---
id: T-186
title: Retire the host Network.framework (`nw`) socket stack
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-182, T-171]
decisions: [0026]
files:
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/TransportKnobsTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/ControlSocketTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/SocketWriteBufferTests.swift
  - backlog/tasks/T-186-host-retire-experiments.md
---

## Amaç

The host still carries a complete experiment stack that lost: the Network.framework (`nw`) control and video sockets. They hit a ~27 Mbps Wi-Fi ceiling with 4 % retransmits, and `bsd` is the default on both sockets. Removing the `nw` stack shrinks `SessionServer` (1,805 lines) to a single socket stack, the one the USB-only profile (T-189) binds to loopback.

This card was split on 2026-10-03 (QA-3). The encoder-side retirements (idle refresh, `FRAME_DELAY`, `PRIO_SPEED`, `H264_PROFILE`, `INPUT_RETAG`) and the host `ev=profile` line moved to **T-204**. The split keeps the `SessionServer.swift` chain (T-171 → T-186) independent of the `HEVCEncoder.swift` chain (T-177 → T-204 → T-187).

Source: external architecture review 2026-10-03 (L02, D8); verification: docs/reviews/2026-10-03/verify-H-hygiene.md (KNOB-H1, L02 inventory row 35).
Decision 0026 must be accepted by the user before work starts, including the user's explicit confirmation of the `nw` retirement (T-182).

## Bağlam

**What goes** (row 35 of the T-182 inventory / `docs/KNOBS.md`; T-091/T-092/T-111; NOTES.md:620-631):
- `MATEBRIDGE_VIDEO_SOCKET`/`MATEBRIDGE_CONTROL_SOCKET` parsing (`host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift:79-95`, `:138-153`).
- In `host-mac/Sources/MateBridgeHost/Session/SessionServer.swift`:
  - `import Network` (`:3`);
  - the `NWConnection` video link case (`:34-38`, `:112-115`);
  - the listener/connection enums (`:336-375`);
  - `bonjourService()` (`:561-562`);
  - the `nw` video listener (`:600`) and `videoListenerState` (`:955`);
  - the `nw` control listener (`:987`);
  - `accept`/`receiveLoop` for `NWConnection` (`:1125`, `:1205`).
- The `NWConnection` variant of `host-mac/Sources/MateBridgeHost/Session/TcpSocketProbe.swift` (`:29`, `:42`, `:103`, `:176`, `:221`).
- The `nw` cases of `testControlSocketKnob` (`host-mac/Tests/MateBridgeCoreTests/Session/ControlSocketTests.swift:266-278`) and `testVideoSocketKnob` (`host-mac/Tests/MateBridgeCoreTests/Session/SocketWriteBufferTests.swift:159-168`). Only those two test functions change in these files. If the knob types disappear entirely, the two test functions go with them.

**What stays:**
- `MATEBRIDGE_SERVICE_CLASS`, `MATEBRIDGE_NOTSENT_LOWAT_KB` and `MATEBRIDGE_SENDQ_LOG` in `TransportKnobs.swift` (debug-only or keep in 0026).
- Every encoder knob; those are T-204's.
- `MATEBRIDGE_WIFI_BITRATE_KBPS` (`TransportBitrate.swift`, not touched here).

**Bonjour:** the kernel-socket control listener registers through `BonjourAdvertiser` (`SessionServer.swift:227-228`, `:1075-1084`). Make sure that remains the only path, and that the TXT `wol=` update (T-128) still works. A WI-5's USB-only hints (`:600`/`:987`) become obsolete with this card. T-189 does not wait for this card: until T-186 merges, its "Yalnız USB" mode forces the `bsd` listeners. If T-189 has merged first, keep its USB-only gate (including the gate in `startBonjour(for:)`) intact while removing the `nw` paths, and drop its now-dead "ignore `nw` knobs" branch only if it lives in `SessionServer.swift`.

**`listening` line** (`SessionServer.swift:1068-1071`): it either drops its `video_socket=`/`control_socket=` fields or keeps them as constants. Pick one and write the LOGGING text under *Açık sorular* for the orchestrator.

**Serialization:**
- `SessionServer.swift` chain: T-163 → T-171 → T-186/T-189 → T-196. **Serialize with T-189 (same file)**: T-189 no longer depends on this card, so whichever of the two merges second rebases onto the other.
- `TcpSocketProbe.swift` and `TransportKnobs.swift`: T-196 edits them later.
- `ControlSocketTests.swift`, `SocketWriteBufferTests.swift` and `TransportKnobsTests.swift` are also inside the `host-mac/Tests/MateBridgeCoreTests/Session/` directory listed by T-152, T-155, T-171, T-189, T-196 and T-202. **Serialize with T-152, T-155, T-189 and T-202 (same files)**: none of them may be in progress at the same time. T-171 is a dependency, and T-196 comes after this card.
- No shared files with T-204. The two halves can run in parallel.

Wire: none.

## Kapsam dışı

- Changing any default.
- Encoder knobs, idle refresh and the host `ev=profile` line (T-204).
- The USB-only profile (T-189); H03 work (T-177/T-178/T-196).

## Kabul kriterleri

- [ ] [XCTest] `ControlSocketTests`, `SocketWriteBufferTests` and `BsdTcpSocketTests` pass. Only `testControlSocketKnob` (ControlSocketTests) and `testVideoSocketKnob` (SocketWriteBufferTests) lose their `nw` cases. `TransportKnobsTests` passes.
- [ ] [XCTest] A grep in Handoff shows no `import Network`, `NWListener` or `NWConnection` left in `MateBridgeHost/Session/`, and no `MATEBRIDGE_VIDEO_SOCKET`/`MATEBRIDGE_CONTROL_SOCKET` parsing in Sources. Comments in `BonjourAdvertiser.swift` and `TransportKnobs.swift` that only mention Network.framework historically may stay.
- [ ] [device] USB and Wi-Fi sessions connect. Bonjour discovery works from the tablet. The Bonjour TXT `wol=` updates (T-128 check). The `listening` line is present.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **`TransportKnobs.swift`:** `VideoSocketKnob` ve `ControlSocketKnob` tipleri silinir (`MATEBRIDGE_VIDEO_SOCKET`/`MATEBRIDGE_CONTROL_SOCKET` artık okunmaz). `VideoSocketSettings` yalnız `notSentLowatKB` taşır; `logFields` sabit `video_socket=bsd notsent_lowat_kb=<n>` verir. `ServiceClassKnob`, `NotSentLowatKnob`, `SendQueueLogKnob` aynen kalır.
2. **`listening` satırı:** alanlar **sabit olarak kalır** (`video_socket=bsd notsent_lowat_kb=<n> control_socket=bsd`), böylece log ayrıştırıcıları ve NOTES karşılaştırmaları kırılmaz. LOGGING metni *Açık sorular*'da.
3. **`SessionServer.swift`:** `nw` yolu tamamen gider: `VideoLink`'in `NWConnection` init/send dalı ve `maxInFlight`/`inFlight`/`sealer` alanları, `ControlListener`/`ControlConnection`/`VideoListener`/`VideoConnection` enum'ları (doğrudan `BsdTcpListener`/`BsdTcpConnection`), `bonjourService()`, `nw` video/kontrol dinleyicileri, `tcpParameters`/`networkServiceClass`/`endpointPort`/`videoListenerState`, `accept(_:video:)`/`receiveLoop`, `closeControl`/`sendControlBytes`/`transport(of:)`/`startTcpInfoSampling`/`recordAudioWrite`/`kernelAudioBacklog` içindeki `.network` dalları ve yalnız `nw` için olan `lingerQueue`. Bonjour tek yol olarak `BonjourAdvertiser` (`startBonjour(for:)`) kalır; TXT `wol=` güncellemesi `republishTxt()` → `bonjour.updateTXT` ile aynen sürer. T-152/T-155/T-163/T-171 davranışı değişmez.
4. **`NWPathMonitor` (T-128):** `wol` yeniden hesaplaması Network.framework'ün `NWPathMonitor`'ünü kullanıyor; bu bir soket değil. `import Network` yerine kapsamlı `import class Network.NWPathMonitor` kullanılır: dosyada `NWListener`/`NWConnection` derleme zamanında görünmez olur, `wol` tetikleyicisi korunur. (Handoff'ta not edilir.)
5. **`TcpSocketProbe.swift`:** yalnız `BsdTcpConnection`; `NWConnection` init'leri, port/descriptor arama, `nw_metadata` geri dönüşü ve `noEndpoints` gider. `import Network` kalkar.
6. **Testler:** `testVideoSocketKnob` ve `testControlSocketKnob` tipleriyle birlikte silinir. `testVideoSocketSettingsLogFields` içindeki tek `nw` beklentisi "eski env değeri yok sayılır" olarak değişir (kart "yalnız iki fonksiyon" diyor; bu satır `nw` çıktısını doğruladığı için değişmek zorunda, Handoff'ta not edilir).
7. `./scripts/check.sh`, Handoff, `status: review`.

**Riskler:** `bsd` yolu zaten varsayılan; davranış değişmemeli. Kapsamlı import'un `NWPath` closure parametresini derlemesi doğrulanacak.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
