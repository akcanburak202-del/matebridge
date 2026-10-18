---
id: T-359
title: Kamera — USB oturumunda da çalışsın (adb reverse 47004)
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-354, T-357]
decisions: [0040]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - client-android/app/src/main/kotlin/dev/matebridge/client/camera/
  - client-android/app/src/test/kotlin/dev/matebridge/client/camera/
  - docs/PROTOCOL.md
  - backlog/tasks/T-359-camera-usb.md
---

## Amaç

Kullanıcı (2026-10-18): kamera USB bağlantısında da çalışsın. Bugün host USB oturumunda `CAMERA_CONTROL(UNAVAILABLE)` gönderiyor (T-354 Open questions): `adb reverse` yalnız 47001/47002'yi taşıyor. Uzak oturumda kamera kapalı kalır (değişmez).

## Kapsam

1. Host USB yolu (`UsbTunnelWatcher` ve ilgili kod): `adb reverse tcp:47004 tcp:47004` de kurulsun ve canlı tutulsun (47001/47002 ile aynı kural ve yaşam döngüsü; yalnız-USB modunda da).
2. USB oturumunda kamera dinleyicisi sabit 47004'te ve loopback'te de dinler; port doluysa fallback port reverse ile ulaşılamaz: o zaman USB'de `UNAVAILABLE` + uyarı logu (Wi-Fi'da bugünkü fallback değişmez). Yalnız-USB modunda (yalnız loopback dinleme, karar 0027) kamera dinleyicisi de yalnız loopback.
3. Eş adres denetimi (kamera eşi = kontrol eşi) USB'de 127.0.0.1 ↔ 127.0.0.1 olarak geçmeli; test.
4. İstemci: kamera bağlantısı zaten kontrol bağlantısının host adresine gider (USB'de 127.0.0.1). Doğrula; gerekiyorsa küçük düzeltme ve test.
5. PROTOCOL.md'yi güncelleme (orkestratör yapar), ama gereken değişikliği Handoff'a yaz (öneri: §3.1 USB reverse listesine 47004 ve "Kamera bağlantısı" maddesine USB notu).

## Kabul

- `./scripts/check.sh` geçer. USB'de kamera cihazda orkestratörle denenir.

## Plan

## Handoff

## Open questions

## Handoff (host)

- Done: `DefaultPorts.camera = 47004`; `UsbTunnelPlanner` default ports are now 47001/47002/47004, so the USB guard installs and keeps `adb reverse tcp:47004` (same lifecycle, also in USB-only mode). Camera over USB no longer reports UNAVAILABLE: removed the `usb_not_supported` log and the "device missing on USB" override in `CameraBridge`.
- `CameraConnectionService.open(loopbackOnly:fixedPortOnly:)`: USB session = fixed 47004 only; if busy, warning `camera_listen state=failed reason=port_busy`, `camera state=unavailable reason=usb_port_busy`, and `CAMERA_CONTROL(UNAVAILABLE)` to the tablet. Wi-Fi keeps the system-port fallback. USB-only network profile (0027) binds the camera listener on IPv4 loopback (`CameraBridge.setUsbOnlyProfile`, called from main at start and on `networkProfileChanged`).
- Peer check: test `usbSessionLoopbackPeerMatchesInEveryForm` (127.0.0.1 and ::ffff:127.0.0.1 in all combinations; other host refused). Planner tests updated for 47004.
- Client: no change needed, `CameraSessionCtx.host` is the session host (127.0.0.1 on USB), so the camera connection goes through the reverse tunnel. Not verified on device.
- PROTOCOL.md suggestion (orchestrator): section 3.1 USB reverse list gets 47004; "Kamera bağlantısı": on USB the camera listener is the fixed 47004 (loopback reachable), no fallback port, busy port gives UNAVAILABLE.
- Needs device: adb reverse list shows 47004; camera works in USB mode and USB-only profile; busy-port UNAVAILABLE.
