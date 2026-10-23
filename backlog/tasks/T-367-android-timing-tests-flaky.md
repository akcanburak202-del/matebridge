---
id: T-367
title: Android — zamanlama testleri yük altında kırmızı (DecoderWaitTest, OutputParkTest, AacDecodeWorkerTest)
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/DecoderWaitTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/OutputParkTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - backlog/tasks/T-367-android-timing-tests-flaky.md
---

## Amaç

2026-10-23'te `./scripts/check.sh` Android adımı `main`'de de kırmızı: makine yükü yüksekken (paralel ajan derlemeleri, load 4–7) `DecoderWaitTest.inputParksWithFewWakeUpsAndTheOutputThreadKeepsPolling` ("output polls 7/8"), `OutputParkTest.withParkOffTheGapsKeepBeingPolled` ("silent polls 41") ve `AacDecodeWorkerTest` başarısız. Ürün kodu değişmeden geçip kalıyorlar: duvar saatine bağlı sayım eşikleri.

## Kabul

1. Testler sahte saat / denetlenen zamanlayıcıyla ya da yükten bağımsız ölçütle yeniden yazılır; ürün davranışı değişmez (ürün kodu değişirse yalnız saat enjeksiyonu için ve Handoff'ta gerekçeli).
2. `stress` altında (ör. arka planda iki `yes > /dev/null` + paralel gradle) 5 ardışık koşu yeşil.
3. `./scripts/check.sh` geçer.

## Plan

## Handoff

## Open questions
