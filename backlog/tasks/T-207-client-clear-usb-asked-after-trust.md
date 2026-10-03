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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
