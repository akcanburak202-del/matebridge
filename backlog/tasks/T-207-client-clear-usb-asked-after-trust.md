---
id: T-207
title: Clear the "asked to pair" mark on a Mac's endpoints once that Mac is trusted, so AUTO returns to USB
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-151]
decisions: [0018]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/AutoTransport.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/TrustUiText.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - backlog/tasks/T-207-client-clear-usb-asked-after-trust.md
---

## Amaç

Cihaz oturumu 2026-10-04 (docs/NOTES.md, 4. adım): Mac'te "Onaylı cihazları unut" sonrası hem USB (`127.0.0.1:47001`) hem Wi-Fi uç noktası PAIRING cevabı verdi. T-151, otomatik bağlantıda PAIRING isteyen adresi kullanıcı başlatana kadar atlıyor (`pair_auto_skip`, AUTO'da `transport_pick reason=usb_lost` olarak görünüyor). Kullanıcı eşleşmeyi Wi-Fi üzerinden tamamladı ve aynı Mac'e artık güveniliyor, ama USB adresindeki işaret kalmadı: AUTO kablo takılıyken Wi-Fi'de kaldı. Ancak "Bağlantıyı kes" + "Bağlan" ile USB'ye döndü.

## Bağlam

- İşaret, sahte bir uç noktanın tableti eşleşme istemine kilitlemesini önlüyor (0018 son madde); bu güvence korunmalı.
- Güven onayı (`pair_trust_confirmed`) ya da güvenilen anahtarla PAIRED bir oturum, o `host_id` için artık eşleşmenin gerekmediğini kanıtlar. O anda, aynı Mac'e ait olduğu bilinen uç noktaların (USB tüneli ve keşfedilen/hatırlanan Wi-Fi adresi) işareti temizlenebilir; bilinmeyen başka adreslerin işareti kalır.
- `transport_pick reason=usb_lost` bu durumda yanıltıcı; ayrı bir neden (`usb_asked`) zaten var (T-151 LOGGING) — doğru neden yazılmalı.

## Kapsam dışı

- Host değişikliği, protokol değişikliği.

## Kabul kriterleri

- [ ] [JVM] Senaryo: USB ve Wi-Fi uç noktaları PAIRING ister → kullanıcı Wi-Fi'de eşleşir ve güvenir → AUTO, kablo takılıyken USB'ye geçer (USB yoklaması ve geçişi yeniden denenir), kullanıcı eylemi gerekmez.
- [ ] [JVM] Güvenilmeyen/başka `host_id`'li bir uç noktanın işareti güven onayıyla temizlenmez (0018 kilitlenme güvencesi).
- [ ] [JVM] PAIRING isteyen USB için seçilen neden `usb_lost` değil `usb_asked` olarak loglanır.
- [ ] [device] "Onaylı cihazları unut" → Wi-Fi'de yeniden eşleş → birkaç saniye içinde `transport_migrate ok=1 to=usb`.

## Plan

1. **Kimlik etiketi (dosya listesi dışı, minimal):** `SessionUi.kt` içine opak `HostTag` (16 bayt host_id, içerik eşitliği, `toString()` değer göstermez, sıfır kimlik = null). `SessionUi.PairingNeedsUser` ve `SessionUi.Connected` birer `hostTag: HostTag? = null` alanı alır. `SessionMachine.Event.PairingNeedsUser` ack'in host_id'sini taşır (`FirstAck`, `SessionController.kt`, tek satır: `ack.hostId`). Makine `Connected`'a etiketi yalnızca oturumun host'u **doğrulanmışken** koyar (ilk mühürlü kayıt görüldü: PAIRED'de güvenilen anahtarla türetilmiş kayıt, eşleşmede yerel "Güven" + host'un mühürlü ACCEPTED'ı). Düz (şifresiz) ilk ack'teki `Connected` etiketsiz kalır.
2. **`PairPick` (TrustUiText.kt):** `asked` artık uç nokta → PAIRING cevabının iddia ettiği `HostTag`. Etiketli bir `Connected` (oturum başına bir kez, etiket değişince) o etiketle işaretlenmiş uç noktaların işaretini kaldırır; başka/bilinmeyen etiketliler işaretli kalır (0018). Kaldırılanlar `takeCleared()` ile alınır.
3. **`AutoTransport.kt`:** `AutoUsbPolicy.onUsbUnblocked(now)` (sayaçlar sıfır, hemen denenebilir); `fallbackReason(ui)`: `PairingNeedsUser` → `usb_asked`, diğerleri `usb_lost`.
4. **`MainActivity.kt`:** `render` → temizlenen uç noktalar `ev=pair_asked_cleared count= usb=` (adres/isim yok); USB temizlendiyse AUTO'da `onUsbUnblocked` + hemen `autoStep`. `fallBackToWifi` nedeni `fallbackReason`'dan.
5. **Testler:** `PairTrustFlowTest` (gerçek kripto: USB ve Wi-Fi PAIRING → Wi-Fi'de eşleş + güven → `Connected` etiketli; aynı etiket → USB işareti kalkar, policy MIGRATE; sahte/başka host_id işaretli kalır), `TrustUiTest` (PairPick), `AutoTransportTest` (`usb_asked`, `onUsbUnblocked`).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
