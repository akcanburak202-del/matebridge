---
id: T-112
title: Tablet testi — InputHandoffTest zaman aşımı testi yük altında ara sıra kırılıyor
status: in_progress
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

- [ ] Kök neden bulunur. `awaitNext` sahte uyanmada erken dönüyorsa kalan süreye kadar beklemeye devam eder (üretim kodu düzeltmesi). Değilse test sağlamlaştırılır, nedeni Handoff'ta yazılır.
- [ ] Sahte uyanmayı zorlayan bir test (örn. bekleyen iş parçacığına `LockSupport.unpark`) erken dönüşü yakalar.
- [ ] Testin kendisi yükte kırılmaz: zaman sınırları alt sınır olarak kalır, üst sınır konmaz.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. Kök neden hipotezi: `awaitNext` tek bir `parkNanos` çağrısından sonra kalan süreye bakmadan dönüyor. `parkNanos` sahte uyanmada ya da iş parçacığında kalmış eski bir izinle (stale permit) hemen döner. Test iş parçacığında eski izin kolayca kalabilir: aynı JUnit iş parçacığı başka testlerde `Semaphore`/`CountDownLatch` (AQS) kullanıyor, `offer` de `waiter` değerini kilit dışında okuyup zaten uyanmış tüketiciyi `unpark` edebiliyor. Önce eski kodla, testte `LockSupport.unpark(Thread.currentThread())` yapıp hatayı deterministik olarak yeniden üret.
2. `FrameQueue.awaitNext`: mutlak bir son tarih (deadline) tut. Kare yoksa ve süre dolmadıysa kalan süreyle yeniden park et. Kesilmiş (interrupted) iş parçacığında döngüde dönüp durmamak için `null` dön, kesme bayrağını koru.
3. Testler (`InputHandoffTest`): (a) önceden kalmış izinle `awaitNext` tam süre bekler; (b) bekleme sırasında başka iş parçacığından tekrarlanan `unpark` erken dönüş yaptırmaz; (c) kesilmiş iş parçacığı `null` alır ve bayrak korunur. Yalnızca alt sınır, üst sınır yok.
4. `./scripts/check.sh`, Handoff.

## Handoff
