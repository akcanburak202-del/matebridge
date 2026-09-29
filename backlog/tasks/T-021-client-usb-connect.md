---
id: T-021
title: Android — "USB ile bağlan" seçeneği
status: review
phase: 1
owner: android-client-dev
depends_on: [T-015]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/res/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
---

## Amaç

USB modunda (PROTOCOL.md §3.1) tabletin `127.0.0.1:47001`'e tek dokunuşla bağlanması. Türkçe Q klavyede `:` yazmak zor (NOTES), elle adres girmek pratik değil.

## Kabul kriterleri

- [ ] Bağlantı panelinde **"USB ile bağlan"** düğmesi: `127.0.0.1:47001`'e elle mod olarak bağlanır (NSD keşfi bu sırada otomatik bağlanmaz). Seçim hatırlanır; bir sonraki açılışta USB modu seçiliyse önce USB denenir, 3 sn içinde bağlanamazsa panelde "USB bağlantısı yok — adb reverse kurulu mu?" gösterilir ve Wi-Fi keşfine dönmek için "Wi-Fi ile bağlan" düğmesi olur.
- [ ] Video bağlantısı, kontrol bağlantısının adresini kullanır (127.0.0.1 + `HELLO_ACK.video_port`); mevcut davranış doğrulanır, gerekirse düzeltilir.
- [ ] İstatistik katmanında bağlantı türü (USB / Wi-Fi) görünür; `MB/session` logunda `transport=usb|wifi`.
- [ ] Mod seçimi mantığı saf ve JVM testli.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

Saf mantık `session/ConnectMode.kt` (Transport, usbEndpoint, transportOf, autoDiscover, showUsbHint) + `Settings.transport()`. MainActivity: onStart'ta kayıtlı moda göre USB (127.0.0.1:47001, NSD kapalı) veya Wi-Fi (NSD); iki düğme; 3 sn sonra host'a ulaşılmadıysa durum metni "USB bağlantısı yok" olur. Video zaten kontrol host'unu kullanıyor (SessionMachine: `Endpoint(ep.host, videoPort)`), değişiklik gerekmedi.

## Handoff

- **Commit:** branch `task/T-021-usb-connect` tip (tek commit)
- **Dokunulan dosyalar:** MainActivity.kt, session/ConnectMode.kt (yeni), session/Settings.kt, res/layout/activity_main.xml, res/values/strings.xml, test/.../session/ConnectModeTest.kt
- **Varsayımlar:** Varsayılan mod Wi-Fi. USB modunda host'a ulaşılamazsa makine yeniden denemeye devam eder; 3 sn sonra yalnızca durum metni ipucuna dönüşür. Ulaşıldı = AwaitingApproval/Connected görüldü. Tür USB = kontrol host'u loopback. Stats katmanına "Bağlantı: USB/Wi-Fi" satırı, logda `ev=transport transport=usb|wifi`.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `adb reverse tcp:47001/47002` ile "USB ile bağlan" akışı; reverse yokken 3 sn sonra ipucu; "Wi-Fi ile bağlan" ile NSD'ye dönüş; uygulama yeniden açılınca mod hatırlanıyor mu; stats katmanı (uzun bas/F3) ve `adb logcat -s MB/session` çıktısı.
- **Açık sorular:**
