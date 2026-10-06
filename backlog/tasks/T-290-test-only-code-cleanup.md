---
id: T-290
title: İstemci — yalnız testte kullanılan üretim kodunu kaldır (FrameQueue.poll, ChromaReuse modelleri)
status: todo
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

## Handoff

## Open questions
