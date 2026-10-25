---
id: T-375
title: Host — PAD_SWIPE (0x18) çöz, Control+ok sistem kısayolu olarak enjekte et
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0043, 0008, 0009]
files:
  - host-mac/Sources/MateBridgeCore/ProtocolConstants.swift
  - host-mac/Sources/MateBridgeCore/Message.swift
  - host-mac/Sources/MateBridgeCore/Messages/
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Sources/MateBridgeHost/Input/CGEventPoster.swift
  - host-mac/Sources/MateBridgeHost/Input/InputController.swift
  - host-mac/Sources/MateBridgeHost/Input/InjectTest.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-375-host-pad-swipe.md
---

## Amaç

Karar 0043: tablet touchpad'inde üç parmak kaydırma Mac'te Mission Control / masaüstü geçişi yapsın. Sözleşme: PROTOCOL.md §4 `0x18 PAD_SWIPE` (alanlar, host kuralları, eşleme tablosu). Fixture'lar: `pad_swipe_up`, `pad_swipe_left`.

## Kabul

1. `PAD_SWIPE` kodlama/çözme, fixture testleri (iki yön de bayt bayt). Bilinmeyen `direction` ve `fingers != 3` yok sayılır (hata değil).
2. Durum makinesi: açık SCROLL/PINCH önce zorla bitirilir; `leftOwner != nil` iken yok sayılır; önceki PAD_SWIPE'tan sonraki 250 ms içinde yok sayılır. Basış tek parça (Control+ok bas, ok bırak, Control bırak) aynı `handle` çağrısının eylemleri olarak çıkar; `heldKeys` ve release-all durumu değişmez. Kullanıcının basılı tuttuğu tuşlar ve değiştiriciler (ör. Ctrl→Command) bu olayın bayraklarına karışmaz ve sonrasında yeniden doğru bayraklarla devam eder. Testler bunları kapsar.
3. CGEvent: ok tuşu sanal kodları (`kVK_UpArrow` 0x7E, `kVK_DownArrow` 0x7D, `kVK_LeftArrow` 0x7B, `kVK_RightArrow` 0x7C). Bayraklar açıkça `maskControl` (+ ok tuşu için `maskSecondaryFn | maskNumericPad`, gerçek klavyenin ürettiği gibi). Control değiştirici tuşu (`kVK_Control` 0x3B) için ayrı bas/bırak olayları da gönderilir; sistem kısayolları bazen yalnız bayrağa değil değiştirici durumuna bakar. Hangisinin gerektiğini bu Mac'te doğrulama yolu: aşağıdaki "Cihaz" notu.
4. Log: `ev=pad_swipe dir=up|down|left|right` (info) ve yok sayıldığında nedeni (`ignored=rate|drag|fingers|dir`). LOGGING.md güncellenir.
5. `InjectTest` gibi var olan bir enjeksiyon aracına `pad_swipe` adımı eklenirse orkestratör sonra elle deneyebilir; zorunlu değil.
6. `./scripts/check.sh` geçer (Android tarafı T-376'da; fixture testi Android'de o zamana kadar kırmızı olabilir, Handoff'ta belirt). **Çalışan host uygulamasına dokunma, Mac'te pencere açma, gerçek olay enjekte etme yok** (tablet Mac'in tek ekranı; Mission Control'ü açmak kullanıcının ekranını değiştirir). Cihaz denemesini orkestratör yapar.

## Plan

## Handoff

## Open questions
