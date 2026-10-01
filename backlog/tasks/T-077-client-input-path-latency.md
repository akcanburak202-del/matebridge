---
id: T-077
title: Tablet — alımdan çözücüye verme gecikmesi (kuyruk→giriş p50 1,16 / p95 2,7 ms; küçük kayıtta 0,6 ms şifre çözme)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-076]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/security/Records.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/FrameDecoder.kt
  - client-android/app/src/test/
  - backlog/tasks/T-077-client-input-path-latency.md
---

## Amaç

İz (`trace6.csv`, 2026-10-01 ~13:40, 60 fps, USB): `recv→decrypted` p50 0,62 / p95 1,19 ms (kareler ~3 KB), `decrypted→queued` 0,05 ms, **`queued→input` p50 1,16 / p95 2,72 / p99 3,51 ms**, çözme p50 8,7 ms. Kuyruktan `queueInputBuffer`'a geçiş `FrameQueue.poll(4)` (`wait/notifyAll`) + `dequeueInputBuffer(4_000)` + kopya. Hedef: bu yolu ≤ 0,3 ms p95'e indirmek; küçük kayıtlarda sabit şifre çözme maliyetini azaltmak.

## Kabul kriterleri

- [ ] Ölç ve ayrıştır (iz sütunu eklemek serbest): uyanma gecikmesi mi, `dequeueInputBuffer` beklemesi mi (giriş tamponu yok), kopya mı.
- [ ] Giriş tamponu bekleme sebebi ise: boşta bir giriş tamponunu önceden al (pre-dequeue) ya da `MediaCodec` asenkron geri çağrı modunda boş giriş indekslerini tut; kare gelince hemen doldur. Uyanma sebebi ise: daha doğrudan devir (ör. ağ iş parçacığı karar verir, giriş iş parçacığı `LockSupport.unpark`), gereksiz zaman aşımlı beklemeleri kaldır. Davranış (sınırlı kuyruk, en yeni kazanır, keyframe kapısı, yapılandırma yeniden oynatma, hata yeniden başlatma) **aynı** kalır.
- [ ] Küçük kayıtta 0,6 ms şifre çözme: nedenini ölç (`cipher.init` + `GCMParameterSpec` tahsisi, JNI geçişleri, ayrıştırma). Güvenli bir iyileştirme varsa yap (tel biçimi ve kripto aynı; fixture/crypto vector testleri geçer); yoksa karta yaz.
- [ ] İz (T-069/T-073) çalışmaya devam eder. `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
