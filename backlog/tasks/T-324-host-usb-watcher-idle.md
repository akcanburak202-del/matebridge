---
id: T-324
title: Host — Wi-Fi'deyken USB tünel izleyicisi ~%1,5 işlemci harcıyor (adb yoklaması); kablo yokken yoklamayı seyrek ya da olay tabanlı yap
status: done
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Usb/UsbTunnelWatcher.swift  # (orchestrator: corrected path)
  - host-mac/Sources/MateBridgeHost/Files/TabletFilesBridge.swift
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Tests/MateBridgeCoreTests/
  - backlog/tasks/T-324-host-usb-watcher-idle.md
---

## Amaç

2026-10-08 trackpad profilinde (Wi-Fi, kablo yok) `dev.matebridge.usb` kuyruğu 8 sn'lik profilde 78 örnek aldı (~%1,5 çekirdek). İzleyici `adb devices` sürecini düzenli başlatıyor (T-228).

## Kabul

1. **Kablo yokken pahalı yoklama yok.** Tercih edilen: IOKit USB cihaz ekleme/çıkarma bildirimi (`IOServiceAddMatchingNotification`, Huawei/Android vendor ID ya da ADB arayüz sınıfı). Bildirim gelince bugünkü `adb devices` yolu çalışır. IOKit uygun değilse kablo yokken yoklama aralığı büyütülür (ör. 2 sn → 10 sn) ve Handoff'ta gerekçelendirilir.
2. **Kablo bağlıyken T-228 davranışı aynen kalır:** ağ adb cihazlarını yok sayma, tünel kurma, kablo çekilince hızlı algılama.
3. **Yeni bağımlılık yok.** IOKit sistem çerçevesi.
4. Saf karar mantığı (ne zaman yokla, ne zaman bekle) Core'da test edilir.
5. Handoff: önce/sonra tahmini uyanma ve süreç başlatma sayısı. Cihaz kontrolü orkestratörde: kabloyu tak ve çıkar, USB geçişi süresi.

## Plan

IOKit `IOUSBHostDevice` first-match + terminated notifications (UsbEventMonitor, same file as the watcher) trigger a probe. The planner (Core) picks the delay: idle (adb healthy, no cable device; network-only adb devices ignored) = 30 s safety net when notifications work, 10 s when IOKit registration failed; after an event, 6 base-rate (2 s) probes; cable attached or an unauthorized/offline device listed = 2 s as before.

## Handoff

- Commit: latest commit on `task/T-324-usb-watcher` ("T-324: ...").
- Files: host-mac/Sources/MateBridgeCore/Usb/UsbTunnelPlanner.swift, host-mac/Sources/MateBridgeHost/Usb/UsbTunnelWatcher.swift (the card's `Session/` path does not exist; the file lives in `Usb/`), host-mac/Tests/MateBridgeCoreTests/Usb/UsbTunnelPlannerTests.swift. TabletFilesBridge untouched.
- check.sh: ALL OK.
- Review round 1 (Codex P2/P3, WIP reviewed and verified; check.sh rc=0): events no longer reschedule the probe; `UsbEventCoalescer` (Core) keeps the earliest pending deadline (0.3 s), so a flapping hub cannot starve probes (test: event every 100 ms for 5 s yields >= 10 probes). Regular chain is restarted after each event probe with the planner's delay (2 s max with a cable, 30/10 s idle). Card `files:` path corrected.
- Review round 2 (Codex P2): `setEnabled` now resets the coalescer; the event probe validates the generation before clearing pending, so a stale probe cannot clear a newer pending flag. Test: testResetOnToggleLetsNewEventSchedule.
- Review round 3 (Codex P2): devices already present at start/enable emit no attach event, so enable now seeds the same burst (`planner.noteUsbEvent()` after reset): 6 probes in total (the immediate one plus 5 at 2 s) before the idle delay. Test: testStartWithDevicePresentFirstProbeEmptyFollowsUpAtBaseRate.
- Estimate: before, idle Wi-Fi = one `adb devices` process (plus a loopback probe) every 2 s, about 30 launches/min. After: one per 30 s, 2/min (~15x fewer), plus a short burst after a USB event. Not measured on a device.
- Assumptions: notification on every `IOUSBHostDevice` (no vendor filter; any USB attach/detach on the Mac costs one probe burst). Cable detach is noticed 0.3 s after the event (faster than the old 2 s worst case). An unauthorized/offline device keeps the 2 s rate because authorization emits no USB event. `testHealthyProbeEndsBackoff` was adjusted to use an unauthorized device, since an empty healthy probe is now idle (10/30 s).
- Needs real hardware (orchestrator): plug/unplug the cable with the host in Wi-Fi mode and USB mode; `ev=usb_tunnel` lines should appear promptly (tunnel up within a few seconds of plug-in, `no_device` after unplug); `dev.matebridge.usb` queue samples should drop in a profile. Also note: an adb server dying while idle is now noticed within up to 30 s.

## Open questions
