---
id: T-218
title: Gate input on video-only loss (stale picture must not keep input live)
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
