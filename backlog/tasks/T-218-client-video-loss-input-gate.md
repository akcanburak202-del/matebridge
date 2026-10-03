---
id: T-218
title: Gate input on video-only loss (stale picture must not keep input live)
status: in_progress
phase: 6
owner: android-client-dev
depends_on: [T-159, T-160]
decisions: [0019]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionMachine.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/SessionController.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/VideoHealth.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - docs/LOGGING.md
  - backlog/tasks/T-218-client-video-loss-input-gate.md
---

## Amaç

gpt-6-astra değerlendirmesi (docs/reviews/2026-10-04/astra-assessment.md, P1 #1): `VideoClosed` yalnız soketi kapalı işaretleyip yeniden bağlanmayı planlıyor; `VideoHealth`'i geçersiz kılmıyor, input'u bırakmıyor. Çalışan ama kare almayan decoder `no_output`/`not_running` kurallarını tetiklemiyor. Sonuç: video TCP bağlantısı kopar ve yeniden bağlanamazken kontrol PONG'ları sürerse, tablette son görüntü donuk dururken kalem ve klavye Mac'e gitmeye devam eder. Yarı açık video soketinde kurulu akış için okuma zaman aşımı da yok.

## Bağlam

- Kanıt: `SessionMachine.kt` ~:445, `VideoHealth.kt` ~:179, `MainActivity.kt` ~:618, `SessionController.kt` ~:884.
- İstenen: bilinen bir video kopması (VideoClosed, video soketi hatası) **hemen** input'u kapatır (mevcut `RELEASE_ALL(USER)` yolu) ve yeniden açılış yeni bir video kuşağının ilk çözülmüş çıktısını bekler (0019 STARTING kuralı).
- Belirsiz sessizlik (yarı açık soket): durağan masaüstünü bozuk video yolundan ayıran sınırlı bir canlılık denetimi. "N sn kare yok" kör kuralı **olmamalı** (0019 bunu reddetti). Aday: video bağlantısında host'un zaten ürettiği canlılık (ör. boşta keyframe/yeniden gönderim aralığı, `KEYFRAME_INTERVAL_S` 300 s) ya da video soketinde TCP keepalive/okuma zaman aşımı; kart ajanı mevcut mekanizmaları inceleyip en küçük güvenli çözümü önerir. Protokol değişikliği gerekiyorsa durup Açık sorular'a yazar.
- 0019 "healthy = decoder çıktısı"; sunum değil. Bu kart kapsamı genişletmez, yalnız video kaybı.

## Kabul kriterleri

- [ ] [JVM] Sağlıklı oturumda VideoClosed → aynı tick'te input kapalı + bırakmalar; yeni video bağlantısının ilk çözülmüş çıktısına kadar kapalı.
- [ ] [JVM] Video yeniden bağlanamazken kontrol PONG'ları sürse bile input kapalı kalır; "Görüntü durdu" katmanı gösterilir.
- [ ] [JVM] Durağan masaüstü (kare yok, video soketi sağlam) yanlış alarm vermez.
- [ ] [device] Akış sırasında video bağlantısını kes (ör. host'ta video soketini kapat / tablette video portunu engelle): tablette katman, Mac'te takılı girdi yok, video dönünce input açılır.

## Plan

Mevcut canlılık incelemesi (kod okuması):
- Host durağan ekranda video soketine hiçbir şey yazmaz. Boşta keyframe (`HEVCEncoder.idleKeyframeNs` 1 sn) yalnız **bekleyen bir keyframe isteği** varken son tamponu yeniden kodlar; `KEYFRAME_INTERVAL_S` (300 sn) yalnız kare akarken geçerli. Yani host tarafında periyodik bir video canlılık sinyali yok.
- Host video soketi: `BsdTcpOptions` varsayılanı, `SO_KEEPALIVE` kapalı. Tablet video soketi: keepalive yok, okuma zaman aşımı yok (`SessionController.VideoConn`).
- T-160 `VideoDeliveryGate`: bir video bağlantısının ilk teslim edilen karesi (`video_gate_open`) belli. `abort()` (yeniden yapılandırma, oturum kaybı, göç) `closedPosted`'ı kurar, bu yüzden `VideoClosed` yalnız **beklenmeyen** kopuşta (EOF, IO/protokol hatası, bağlanamama, anahtar yok) gelir.
- T-205: kanıt beklenirken (`candAck != null`) eski videonun kapanması beklenen bir durumdur (host devralıyor). Mevcut test bu durumda eylem olmamasını istiyor.

En küçük güvenli çözüm (protokol değişikliği yok):
1. **Bilinen kopuş → aynı anda input kapalı.** `SessionMachine`, STREAMING'de geçerli video kuşağının `VideoClosed`'ında yeni `Action.VideoLost(gen)` üretir. Kanıt beklenirken üretmez; aday başarısız olur ve eski oturum kalırsa o zaman üretir. Makinenin `inputAllowed`'ı **değişmez**: kontrol bağlantısı açık kalır, bırakmalar (`RELEASE_ALL(USER)`) reddedilmez.
2. `SessionController`: `SessionListener.onVideoLost(gen)` (motor iş parçacığı) ve `onVideoFlowing(gen)` (yeni video bağlantısının ilk teslim edilen karesi, bağlantı başına bir kez).
3. `VideoHealth`: yeni `FaultCause.VIDEO_LOST` (`video_lost`). `videoLost()` → FAULT; mevcut yol input'u kapatır (`syncInputActive` → `RELEASE_ALL(USER)`), beslemeyi durdurur, "Görüntü durdu" katmanını gösterir, kurtarma merdiveni işler (+1/+3 sn decoder, +6 sn oturum, +15 sn "Yeniden dene"). `videoFlowing()`: FAULT(video_lost) iken RESTART_CODEC döner, yani yeni bir decoder kuşağı. Kuşak STARTING'dedir; ilk çözülmüş çıktısında HEALTHY olur (0019). Eski bağlantının kareleri kuyruk sıfırlamasıyla düşer.
4. **Belirsiz sessizlik (yarı açık soket):** tablet video soketinde TCP keepalive açılır (`SO_KEEPALIVE`, `TCP_KEEPIDLE` 3 sn, `TCP_KEEPINTVL` 1 sn, `TCP_KEEPCNT` 3). Ayar QuickAck gibi kopyalanmış fd üzerinden `Os.setsockoptInt` ile yapılır. Durağan masaüstünde Mac çekirdeği probu ACK'ler, yanlış alarm yok. Ölü ya da sıfırlanmış uçta okuma ≤ ~6 sn'de ETIMEDOUT/ECONNRESET ile biter ve olağan `VideoClosed` → 1. adım işler. Bu, kontrolün PONG zaman aşımından (3 sn) daha gevşektir. "N sn kare yok" kuralı yok. Ayar başarısız olursa yalnız loglanır, oturuma dokunmaz. Saf `VideoKeepalive` nesnesi sahte setter'la JVM'de test edilir.
5. JVM testleri: `SessionMachine` VideoLost (geçerli, eski, kanıt bekleme, aday başarısızlığı); `VideoHealth` (aynı çağrıda kapanma, PONG'lar sürerken kapalı kalma + katman, akış dönünce yeniden başlatma ve ilk çıktıda açılma, durağan masaüstü); keepalive ayarları.
6. `docs/LOGGING.md`: `cause=video_lost`, `video_recover step=resume`, `ev=video_keepalive`.

Kapsam dışı (Açık sorular'a): host video hattı canlı ama takılı (Mac çekirdeği ACK'ler) durumu; USB (`adb reverse`, loopback) üzerinde keepalive yerel uca gider.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
