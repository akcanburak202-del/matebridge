---
id: T-012
title: Android oturum istemcisi — NSD keşif, bağlantı, onay bekleme, heartbeat, yeniden bağlanma
status: review
phase: 1
owner: android-client-dev
depends_on: [T-009]
decisions: [0004]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/
  - client-android/app/src/main/AndroidManifest.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
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

- `SessionMachine`: saf olay->eylem durum makinesi (bağlantı "generation" numarasıyla eski bağlantı olayları yok sayılır), 500 ms PING, 3 sn PONG yok = kapat + geri çekilmeli (1->5 sn) yeniden bağlan, BUSY en az 3 sn, REJECTED/VERSION_MISMATCH otomatik yeniden denemez.
- `SendQueue`: 256 KiB / 1 sn sınırlı tek FIFO; taşarsa bağlantı kapanıp yeniden bağlanır (birleştirme girdi görevlerinde).
- `SessionController`: ayrı iş parçacıkları (motor, okuyucular, yazıcı); ana iş parçacığında soket yok. Yeni bağımlılık yok (düz Thread).
- `MacDiscovery` (NsdManager), `Settings` (device_id + son IP:port), `MainActivity` + res.

## Handoff

- **Commit:** dal task/T-012-client-session, son commit `T-012: ...`
- **Dokunulan dosyalar:** session/{Endpoint,SessionUi,SendQueue,SessionMachine,SessionController,MacDiscovery,Settings}.kt, MainActivity.kt, res/layout/activity_main.xml, res/values/strings.xml, AndroidManifest.xml, test/.../session/{SessionMachineTest,SessionSupportTest}.kt (27 test)
- **Varsayımlar:** coroutines yerine düz thread. CHANGE_WIFI_MULTICAST_STATE eklenmedi (NsdManager gerektirmez). NSD yalnızca IPv4 adres çözer. Activity onStop'ta BYE ile kapanır, onStart'ta yeniden keşif yapar. `SessionListener.onStreamConfig/onVideoFrame` T-013 bağlantı noktası; kareler yalnızca sayılır (fragmentIndex==0). `SessionController.trySend` ACCEPTED öncesi false döner.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Soket/NSD/UI katmanı yalnızca cihazda: (1) Mac host çalışırken uygulama Mac'i NSD ile bulup bağlanıyor mu, (2) yeni cihazda 'Mac'te onay bekleniyor', onay sonrası 'Bağlı' + kare sayacı artıyor mu, (3) IP:port elle girip bağlanma ve son değerin hatırlanması, (4) host'u kapatınca 'Bağlantı yok' + otomatik yeniden bağlanma, (5) uygulamayı arka plana atınca Mac'te oturumun BYE ile kapanması. Wi-Fi ağ değişimi denenmedi.
- **Açık sorular:** yok.
