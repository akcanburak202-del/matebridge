---
id: T-031
title: Mac — kalem yakınlık olayında cihaz kimliği (vendorPointerType, uniqueID); Krita kalemi fare sanıyor
status: todo
phase: 2
owner: mac-host-dev
depends_on: [T-023]
decisions: [0006]
files:
  - host-mac/Sources/MateBridgeHost/Input/CGEventPoster.swift
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Tests/MateBridgeCoreTests/Input/
  - backlog/tasks/T-031-host-tablet-device-identity.md
---

## Amaç

T-027: kalemin çift dokunuşu (karar 0006) Krita'da silgi fırçasına geçirmiyor. Kök neden bulundu (NOTES 2026-09-30 "Krita çift dokunma"):

- Host'un `tabletProximity` olayı (`CGEventFactory.proximity`) `vendorPointerType` ve `uniqueID` alanlarını doldurmuyor (0).
- Qt 5.15 macOS (`qnsview_tablet.mm`, `wacomTabletDevice`) cihaz türünü `vendorPointingDeviceType`'tan çıkarıyor. 0 ise (ve `uniqueID` 0 ise) `QTabletEvent::NoDevice`. Kural: `(bits & 0x0006) == 0x0002 && (bits & 0x0F06) != 0x0902` → `Stylus`.
- Krita `KoInputDevice::isMouse()` cihaz türü bilinmeyen her girdiyi fare sayıyor; `switchInputDevice` fare→fare geçişini yok sayıyor. Krita'nın tablet günlüğünde her olay `NoDevice ... id: 0`; işaretçi türü (`Pen`/`Eraser`) ise doğru.

## Kabul kriterleri

- [ ] Yakınlık olayı (giriş ve çıkış) `tabletProximityEventVendorPointerType` alanını taşır: kalem `0x0802`, silgi `0x080A` (Wacom kodları; ikisi de Qt kuralıyla `Stylus`).
- [ ] Yakınlık olayı `tabletProximityEventVendorUniqueID` alanında sıfırdan farklı, **sabit** bir kimlik taşır (kalem ve silgi için aynı; gerçek bir kalemin iki ucu gibi). Krita ön ayarları bu kimlikle hatırlıyor (`LastPreset_<id>`), bu yüzden süreçten sürece ve oturumdan oturuma değişmemeli.
- [ ] Mevcut alanlar (`pointerType` 1/3, deviceID, capability mask, vendorID…) değişmez; tablet nokta olayları değişmez.
- [ ] Değerler test edilebilir bir yerde durur (ör. `MateBridgeCore/Input` altında saf bir eşleme: `PenTool` → vendor pointer type; sabit uniqueID) ve birim testi vardır: kalem ve silgi değerleri farklıdır, ikisi de Qt'nin kuralına göre `Stylus` sayılır (kural testte yeniden yazılır); uniqueID ≠ 0 ve sabittir.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tel biçimi ve PROTOCOL.md değişmez.
- Gerçek olay gönderme yok (alt ajanlar kullanıcının Mac'ine girdi olayı göndermez). Cihaz/Krita doğrulaması orkestratörde: Krita tablet günlüğünde `Stylus Pen id: <sabit>` ve çift dokunmadan sonra `Stylus Eraser`, fırçanın silgiye geçmesi.
- Faz 0 probu (`probes/pen-sink-probe`) değişmez.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
