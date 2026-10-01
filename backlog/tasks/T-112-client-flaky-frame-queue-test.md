---
id: T-112
title: Tablet testi — InputHandoffTest zaman aşımı testi yük altında ara sıra kırılıyor
status: done
phase: 5
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt
  - client-android/app/src/test/
  - backlog/tasks/T-112-client-flaky-frame-queue-test.md
---

## Amaç

2026-10-01'de `check.sh` bir kez kırıldı (makine yüklüyken): `InputHandoffTest.awaitNextReturnsAQueuedFrameAtOnceAndNullOnTimeout` satır 26'da (`System.nanoTime() - t0 >= 15_000_000L`) başarısız oldu.
- `FrameQueue.awaitNext(20 ms)` beklenenden erken `null` döndü.
- Olası nedenler:
  - `parkNanos` sahte uyanmada kalan süre hesaplanmadan dönülüyor; bu gerçek bir hata olurdu;
  - test ölçümü yanlış.

## Kabul kriterleri

- [x] Kök neden bulunur. `awaitNext` sahte uyanmada erken dönüyorsa kalan süreye kadar beklemeye devam eder (üretim kodu düzeltmesi). Değilse test sağlamlaştırılır, nedeni Handoff'ta yazılır.
- [x] Sahte uyanmayı zorlayan bir test (örn. bekleyen iş parçacığına `LockSupport.unpark`) erken dönüşü yakalar.
- [x] Testin kendisi yükte kırılmaz: zaman sınırları alt sınır olarak kalır, üst sınır konmaz.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. Kök neden hipotezi: `awaitNext` tek bir `parkNanos` çağrısından sonra kalan süreye bakmadan dönüyor. `parkNanos` sahte uyanmada ya da iş parçacığında kalmış eski bir izinle (stale permit) hemen döner. Test iş parçacığında eski izin kolayca kalabilir: aynı JUnit iş parçacığı başka testlerde `Semaphore`/`CountDownLatch` (AQS) kullanıyor, `offer` de `waiter` değerini kilit dışında okuyup zaten uyanmış tüketiciyi `unpark` edebiliyor. Önce eski kodla, testte `LockSupport.unpark(Thread.currentThread())` yapıp hatayı deterministik olarak yeniden üret.
2. `FrameQueue.awaitNext`: mutlak bir son tarih (deadline) tut. Kare yoksa ve süre dolmadıysa kalan süreyle yeniden park et. Kesilmiş (interrupted) iş parçacığında döngüde dönüp durmamak için `null` dön, kesme bayrağını koru.
3. Testler (`InputHandoffTest`): (a) önceden kalmış izinle `awaitNext` tam süre bekler; (b) bekleme sırasında başka iş parçacığından tekrarlanan `unpark` erken dönüş yaptırmaz; (c) kesilmiş iş parçacığı `null` alır ve bayrak korunur. Yalnızca alt sınır, üst sınır yok.
4. `./scripts/check.sh`, Handoff.

## Handoff

- **Commit:** `0cae8d3` (fix + tests; plan `e2b1257`), branch `task/T-112-client-flaky-frame-queue-test`.
- **Kök neden (üretim hatası):** `awaitNext` tek bir `LockSupport.parkNanos(timeout)` çağrısından sonra kalan süreye bakmadan `take()` sonucunu döndürüyordu. `parkNanos` iş parçacığında kalmış eski bir izinle hemen, sahte uyanmada da erken döner. Testte eski izin şöyle oluşuyor: JUnit sırası `offerWakesAParkedConsumerLongBeforeItsTimeout` → `queueRulesAreUnchangedThroughAwaitNext` → `awaitNextReturnsAQueuedFrameAtOnceAndNullOnTimeout`, hepsi aynı test iş parçacığında. İlk test ana iş parçacığında `CountDownLatch.await()` (AQS) çağırıyor. Yük altında `countDown` ile `await` yarışırsa, ana iş parçacığı park etmeden geçtikten sonra AQS onu `unpark` edebilir ve iş parçacığında bir izin kalır. Aradaki test park etmediği için bu izin 20 ms'lik beklemeyi 0 ms'ye indiriyordu. Üretimde de aynı yol var: `offer`, `waiter` değerini kilit dışında okuyup zaten kare almış tüketiciyi `unpark` edebiliyor. Sonraki `awaitNext` hemen `null` döner. Decoder döngüsü bunu `continue` ile tolere ettiği için zarar yoktu, sadece boş bir tur dönülüyordu.
- **Düzeltme:** mutlak son tarih eklendi. Kare yoksa kalan süreyle yeniden park ediliyor. Kesilmiş iş parçacığında `parkNanos` bloklamadığı için dönüp durmak yerine `null` dönülüyor, bayrak korunuyor. Decoder iş parçacığı `interrupt` ile durdurulmuyor (`att.active`), davranışı değişmiyor.
- **Testler (`InputHandoffTest`):** `aStalePermitDoesNotCutTheWaitShort` (önceden `unpark(self)`), `spuriousWakeUpsWhileParkedDoNotCutTheWaitShort` (bekleyen tüketiciye 2 ms'de bir `unpark`, ≥100 ms), `anInterruptedConsumerGetsNullAndKeepsTheFlag`. İlk ikisi eski kodda deterministik olarak kırıldı (`returned after 0 ms`). Eski testin alt sınırı 15 ms'den 20 ms'ye (tam timeout) çıkarıldı. Bu artık matematiksel olarak garanti. Hiçbir testte üst sınır yok.
- **Doğrulama:** `./scripts/check.sh` ALL OK. `InputHandoffTest` tüm çekirdeklerde `yes` yükü altında 5 kez `--rerun-tasks` ile çalıştırıldı, 0 hata.
- **Dokunulan dosyalar:** `video/FrameQueue.kt`, `test/.../video/InputHandoffTest.kt`, bu kart.
- **Tablette kontrol:** davranış değişikliği yalnızca boşta bekleme yolunda. Normal bir yayında görüntü akıcı olmalı, regresyon olmamalı. İsteğe bağlı: boşta (statik ekran) `mb-decoder-in` CPU kullanımı öncekinden yüksek olmamalı.
- **Test edilmedi:** cihazda çalıştırılmadı.
