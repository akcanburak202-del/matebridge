---
id: T-021
title: Android — "USB ile bağlan" seçeneği
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
