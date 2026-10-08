---
id: T-324
title: Host — Wi-Fi'deyken USB tünel izleyicisi ~%1,5 işlemci harcıyor (adb yoklaması); kablo yokken yoklamayı seyrek ya da olay tabanlı yap
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Session/UsbTunnelWatcher.swift
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

## Handoff

## Open questions
