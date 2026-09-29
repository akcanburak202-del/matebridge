---
id: T-020
title: Mac — sabit varsayılan portlar ve USB modu betiği
status: todo
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

- [ ] Dinleyiciler önce kontrol **47001**, video **47002** portlarını dener; port doluysa (başka bir MateBridge örneği vb.) sistemin verdiği porta düşer ve bunu loglar. Dinleyici yeniden başlatmada (T-010 geri çekilme) aynı sıra.
- [ ] Port seçimi mantığı saf ve Core'da testli (tercih → dolu → geri düşüş).
- [ ] `scripts/usb-mode.sh [on|off|status]`: `adb reverse tcp:47001 tcp:47001` ve `tcp:47002 tcp:47002` kurar/kaldırır/listeler. adb bulunamazsa ya da cihaz yoksa anlaşılır mesaj. adb sunucusunun ara sıra açılamamasına karşı (NOTES 2026-09-29) birkaç deneme.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
