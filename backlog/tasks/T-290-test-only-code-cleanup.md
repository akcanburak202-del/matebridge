---
id: T-290
title: İstemci — yalnız testte kullanılan üretim kodunu kaldır (FrameQueue.poll, ChromaReuse modelleri)
status: done
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/FrameQueue.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/ChromaReuse.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-290-test-only-code-cleanup.md
---

## Amaç

Astra incelemesi 2026-10-07, P3 (`docs/reviews/2026-10-07/astra-review.md`):
- `FrameQueue.poll()`'u üretimde çağıran yok. Testler kuyruğu bu yoldan boşaltıyor; bu yol, üretimin kullandığı `awaitNext`/`take` yolundaki nesil sahipliğini ve yakalama mantığını atlıyor. Bu yüzden üretim yolu bozulduğunda testler yine yeşil kalabilir.
- `Planes420` ve `ChromaReuseModel` yalnız `ChromaReuseTest` içinde kullanılıyor.

Davranış değişmez.

## Kabul

1. Kuyruk testleri üretim API'si üzerinden tüketir (açık sahiplikle). `FrameQueue.poll()` silinir.
2. `Planes420`/`ChromaReuseModel` test kaynağına taşınır. Üretimde kullanılan sabitler ve politikalar yerinde kalır.
3. Testlerin kapsadığı senaryolar azalmaz (taşınan her test aynı iddiayı korur). `./scripts/check.sh` geçer.

## Plan

1. `FrameQueue.poll(timeoutMs)` ve onu bekleyen tek `lock.notifyAll()` (offer içinde; artık bekleyen yok) silinir. Başka kimse `lock.wait` yapmıyor (grep).
2. Testler için `FrameQueueTestSupport.kt`: `ownedByTest()` (kuyruğa `assignConsumer(1)`) ve `takeNow()` (= `awaitNext(0, 1)`). `VideoTest` (FrameQueueTest) ve `FrameQueueBurstTest` içindeki her `q.poll(0)` bu yola çevrilir; iddialar aynı.
3. `Planes420` ve `ChromaReuseModel` `ChromaReuse.kt`'den test kaynağına (`ChromaReuseModel.kt`) taşınır. `ChromaReuse` (TOLERANCE, blockUnchanged), `LateUpgrade`, `FirstShown`, `DrawWatch` üretimde kalır.
4. `./scripts/check.sh`.

## Handoff

- Commit: (bkz. `git log task/T-290-test-only-code-cleanup`, tek commit `T-290: ...`)
- Dosyalar: `FrameQueue.kt` (poll + ölü notifyAll silindi, kdoc), `ChromaReuse.kt` (Planes420/ChromaReuseModel çıkarıldı), test: yeni `ChromaReuseModel.kt` (taşınan modeller), yeni `FrameQueueTestSupport.kt` (`ownedByTest`/`takeNow`), `VideoTest.kt` ve `FrameQueueBurstTest.kt` (poll(0) -> takeNow()), bu kart.
- `./scripts/check.sh`: ALL OK. Hiçbir test eklenmedi/silinmedi; her `poll(0)` aynı iddiayla `awaitNext(0, owner)` olarak çalışıyor (catch-up kapalı olduğundan davranış aynı).
- Varsayım: `lock.notifyAll()` yalnız `poll`'un `lock.wait`'i içindi (başka `wait` yok); `awaitNext` park/unpark kullanıyor. Üretim davranışı değişmedi.
- Tablette bir şey yok: yalnız JVM testleri etkilendi, üretim yolu (`awaitNext`/`take`) aynı. İstenirse bir akış açılışı smoke kontrolü yeter.

## Open questions
