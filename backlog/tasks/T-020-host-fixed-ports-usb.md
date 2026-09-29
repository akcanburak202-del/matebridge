---
id: T-020
title: Mac — sabit varsayılan portlar ve USB modu betiği
status: done
phase: 1
owner: mac-host-dev
depends_on: [T-014]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - scripts/usb-mode.sh
---

## Amaç

USB modunu (PLAN Aşama 1: "Aynı kodla USB modu (adb reverse) çalışıyor") elle port aramadan kullanılabilir yapmak. PROTOCOL.md §3.1 varsayılan portlar.

## Kabul kriterleri

- [x] Dinleyiciler önce kontrol **47001**, video **47002** portlarını dener; port doluysa (başka bir MateBridge örneği vb.) sistemin verdiği porta düşer ve bunu loglar. Dinleyici yeniden başlatmada (T-010 geri çekilme) aynı sıra.
- [x] Port seçimi mantığı saf ve Core'da testli (tercih → dolu → geri düşüş).
- [x] `scripts/usb-mode.sh [on|off|status]`: `adb reverse tcp:47001 tcp:47001` ve `tcp:47002 tcp:47002` kurar/kaldırır/listeler. adb bulunamazsa ya da cihaz yoksa anlaşılır mesaj. adb sunucusunun ara sıra açılamamasına karşı (NOTES 2026-09-29) birkaç deneme.
- [x] `./scripts/check.sh` geçiyor.

## Plan

ListenerPortPlan (Core, saf): tercih, sonra 0, sonra nil. SessionServer her dinleyicide plan kullanır; sabit port başarısız olursa (init throw ya da .failed) loglayıp sistem portuna düşer. Yeniden başlatmada yeni plan. usb-mode.sh: adb reverse on/off/status, 4 deneme.

## Handoff

- **Commit:** 7f8e139
- **Dokunulan dosyalar:** SessionServer.swift, Core/Session/ListenerPortPlan.swift, Tests/.../ListenerPortPlanTests.swift, scripts/usb-mode.sh, bu kart
- **Varsayımlar:** NWListener dolu portta .failed olur (ya da init fırlatır); ikisi de ele alındı. SessionServer varsayılanı artık 47001/47002.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Gerçek port çakışmasında geri düşüş (yalnız plan mantığı testli); usb-mode.sh tablet bağlıyken on/off; Android 127.0.0.1:47001 bağlantısı.
- **Açık sorular:**

## Orkestratör cihaz testi (2026-09-30)

Cihaz: host 47001/47002'de dinliyor. `usb-mode.sh on` tünelleri kuruyor. İlk sürümde durum kontrolü adb başlangıç satırlarını ayrıştırıyordu (düzeltildi), sonra adb sunucusunun mDNS köprüsündeki çökmesi yüzünden tüneller kayboluyordu: betik artık adb'yi launchd altında `ADB_MDNS=0` ile çalıştırıyor. Port çakışması geri düşüşü cihazda denenmedi.

