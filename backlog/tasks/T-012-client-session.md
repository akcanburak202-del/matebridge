---
id: T-012
title: Android oturum istemcisi — NSD keşif, bağlantı, onay bekleme, heartbeat, yeniden bağlanma
status: todo
phase: 1
owner: android-client-dev
depends_on: [T-009]
decisions: [0004]
files:
  - client-android/app/src/main/java/dev/matebridge/client/session/
  - client-android/app/src/main/java/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/test/java/dev/matebridge/client/session/
---

## Amaç

Tabletin Mac'i bulup oturum açması: PROTOCOL.md §2, §3, §6'nın istemci tarafı. Video çözme yok (T-013); video bağlantısı açılır, `VIDEO_HELLO` gönderilir, gelen kareler şimdilik yalnızca sayılır.

## Kabul kriterleri

- [ ] Oturum durum makinesi saf Kotlin ve JVM testli: HELLO, PENDING bekleme, ACCEPTED, REJECTED/BUSY/VERSION_MISMATCH, 500 ms PING, 3 sn PONG yoksa yeniden bağlanma, BYE, `STREAM_CONFIG` sonrası video bağlantısı ve `config_id` değişiminde yeniden açma.
- [ ] `device_id` ilk açılışta rastgele üretilip saklanır.
- [ ] `NsdManager` ile `_matebridge._tcp` keşfi; bulunamazsa elle IP:port girişi (son değer hatırlanır).
- [ ] Arayüz durumları: aranıyor / bağlanıyor / "Mac'te onay bekleniyor" / bağlı (Mac adı, gelen kare sayısı) / "Bağlantı yok" + otomatik yeniden deneme.
- [ ] Soket G/Ç ana iş parçacığında değil. Gönderim tek FIFO (§7), sınırlı (§5).
- [ ] Ağ izinleri manifestte (INTERNET, ACCESS_NETWORK_STATE, CHANGE_WIFI_MULTICAST_STATE gerekiyorsa).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
