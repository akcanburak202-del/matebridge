---
id: T-012
title: Android oturum istemcisi — NSD keşif, bağlantı, onay bekleme, heartbeat, yeniden bağlanma
status: done
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

- [x] Oturum durum makinesi saf Kotlin ve JVM testli: HELLO, PENDING bekleme, ACCEPTED, REJECTED/BUSY/VERSION_MISMATCH, 500 ms PING, 3 sn PONG yoksa yeniden bağlanma, BYE, `STREAM_CONFIG` sonrası video bağlantısı ve `config_id` değişiminde yeniden açma.
- [x] `device_id` ilk açılışta rastgele üretilip saklanır.
- [x] `NsdManager` ile `_matebridge._tcp` keşfi; bulunamazsa elle IP:port girişi (son değer hatırlanır).
- [x] Arayüz durumları: aranıyor / bağlanıyor / "Mac'te onay bekleniyor" / bağlı (Mac adı, gelen kare sayısı) / "Bağlantı yok" + otomatik yeniden deneme.
- [x] Soket G/Ç ana iş parçacığında değil. Gönderim tek FIFO (§7), sınırlı (§5).
- [x] Ağ izinleri manifestte (INTERNET, ACCESS_NETWORK_STATE, CHANGE_WIFI_MULTICAST_STATE gerekiyorsa).
- [x] `./scripts/check.sh` geçiyor.

## Plan

- `SessionMachine`: saf olay->eylem durum makinesi (bağlantı "generation" numarasıyla eski bağlantı olayları yok sayılır), 500 ms PING, 3 sn PONG yok = kapat + geri çekilmeli (1->5 sn) yeniden bağlan, BUSY en az 3 sn, REJECTED/VERSION_MISMATCH otomatik yeniden denemez.
- `SendQueue`: 256 KiB / 1 sn sınırlı tek FIFO; taşarsa bağlantı kapanıp yeniden bağlanır (birleştirme girdi görevlerinde).
- `SessionController`: ayrı iş parçacıkları (motor, okuyucular, yazıcı); ana iş parçacığında soket yok. Yeni bağımlılık yok (düz Thread).
- `MacDiscovery` (NsdManager), `Settings` (device_id + son IP:port), `MainActivity` + res.

## Handoff

- **Commit:** kod son hali 3a45b5c (dal task/T-012-client-session; sonraki commit yalnızca bu satır)
- **Dokunulan dosyalar:** session/{Endpoint,SessionUi,SendQueue,SessionMachine,SessionController,MacDiscovery,Settings}.kt, MainActivity.kt, res/layout/activity_main.xml, res/values/strings.xml, AndroidManifest.xml, test/.../session/{SessionMachineTest,SessionSupportTest}.kt (27 test)
- **Varsayımlar:** coroutines yerine düz thread. CHANGE_WIFI_MULTICAST_STATE eklenmedi (NsdManager gerektirmez). NSD yalnızca IPv4 adres çözer. Activity onStop'ta BYE ile kapanır, onStart'ta yeniden keşif yapar. `SessionListener.onStreamConfig/onVideoFrame` T-013 bağlantı noktası; kareler yalnızca sayılır (fragmentIndex==0). `SessionController.trySend` ACCEPTED öncesi false döner.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Soket/NSD/UI katmanı yalnızca cihazda: (1) Mac host çalışırken uygulama Mac'i NSD ile bulup bağlanıyor mu, (2) yeni cihazda 'Mac'te onay bekleniyor', onay sonrası 'Bağlı' + kare sayacı artıyor mu, (3) IP:port elle girip bağlanma ve son değerin hatırlanması, (4) host'u kapatınca 'Bağlantı yok' + otomatik yeniden bağlanma, (5) uygulamayı arka plana atınca Mac'te oturumun BYE ile kapanması. Wi-Fi ağ değişimi denenmedi. Review düzeltmeleri (overflow'da zorunlu yeniden bağlanma, motor iş parçacığının bloklanmaması, NSD durdurma koruması, kapanış zaman aşımı) yalnızca kısmen JVM testli (SendQueue/ControlLink); SessionController iş parçacığı, tıkanma ve yeniden bağlanma yolları cihazda/elle test edilmedi.
- **Açık sorular:** yok.

## Orkestratör cihaz testi (2026-09-29)

Canlı test: NSD keşfi (192.168.1.105), HELLO, PENDING ekranı, ACCEPTED sonrası "Bağlı: <Mac adı>", STREAM_CONFIG ve video bağlantısı açıldı. Uygulama yeniden başlatılınca onaysız bağlandı. Host kapanınca `connect_fail` + 2 s / 4 s geri çekilme, host açılınca kendiliğinden bağlandı. Arka plana geçince BYE gönderiliyor (tasarım gereği). T-012b ile `MB/session` logları eklendi.
