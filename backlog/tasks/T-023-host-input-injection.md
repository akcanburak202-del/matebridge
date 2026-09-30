---
id: T-023
title: Mac girdi enjeksiyonu — CGEvent kalem/fare, koordinat dönüşümü, oturuma bağlama
status: todo
phase: 2
owner: mac-host-dev
depends_on: [T-022]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Input/Geometry+Display.swift
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/MateBridgeCoreTests/Input/
---

## Amaç

T-022'nin `InjectAction`'larını gerçek macOS olaylarına çevirmek ve oturumdan gelen girdi mesajlarını bağlamak.

## Kabul kriterleri

- [ ] `CGEventInjector` (Host): Faz 0'da doğrulanan yöntem (`probes/pen-sink-probe` PenInjection, NOTES 2026-09-29): tablet proximity (capability mask 0x25C7, pointerType pen/eraser), `leftMouseDown/Dragged/Up` + `tabletPoint` alt tipi, basınç, eğim; hover için `mouseMoved`; sağ/orta düğmeler.
- [ ] **Koordinat dönüşümü tek yerde** (Core, testli): normalize (u16) → sanal ekranın global nokta koordinatları (`CGDisplayBounds`), §1'deki sıkıştırma. Sanal ekran yoksa girdi yok sayılır.
- [ ] Oturum bağlama: `SessionServer` `deliver` → T-022 durum makinesi → injector. `releaseInput` gerçek release-all yapar. Watchdog tick'i oturum kuyruğunda.
- [ ] **Accessibility izni**: yoksa girdi enjekte edilmez, menüde "Erişilebilirlik izni gerekli" + Sistem Ayarları'nı açan menü öğesi; çökme yok. MateBridge.app kendi kimliğiyle izin ister.
- [ ] Çift tıklama için `mouseEventClickState` (§4 POINTER_REL notu) — tek dokunuş/çift dokunuş zamanlamasıyla.
- [ ] Doğrulama aracı: `MateBridgeApp --inject-test` benzeri bir mod, fixture PEN mesaj dizisini (ör. `pen_hover_to_contact`) sanal ekrana enjekte eder; orkestratör Krita'da kontrol eder.
- [ ] `./scripts/check.sh` geçiyor.

## Notlar (T-022 incelemesinden, 2026-09-30)

T-022'nin `InputStateMachine`'ini tüketirken uyulacak sözleşme (PROTOCOL.md §4 ve §7, aynı tarihli netleştirmeler):

- **Oturum başına yeni makine.** Bir oturumun makinesi sonrakine taşınmaz.
- **Tek saat.** `handle(_:now:)` ve `tick(now:)` aynı monoton saatten (`HostClock`) beslenir. Zamanlayıcı `nextDeadline(now:)`'a göre kurulur (mutating; makine `var` olarak tutulur).
- **Tek kuyruk.** Makine kilitsiz bir değer tipidir; mesaj, tick ve release-all yalnızca oturum kuyruğundan çağrılır.
- **`mouseButton` imlecin o anki konumunda uygulanır.** Injector son enjekte ettiği konumu tutar.
- **Kaydırma:** sıfır deltalı `CHANGED` (istemcinin canlılık mesajı) enjekte edilmez. Zorla bitirilen hareket ENDED olarak enjekte edilir ve atalet üretilmez. Release-all, süren ataleti de durdurur (makinede bunun durumu yok; injector'ın işi).
- Kritik: bu kart da Codex `--high` incelemesinden geçer.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
