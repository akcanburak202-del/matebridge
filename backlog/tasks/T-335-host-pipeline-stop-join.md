---
id: T-335
title: Host — pipeline teardown sürerken ikinci stop çağıranı beklesin; hata zamanı teardown'dan önce alınsın
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-325, T-293]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/PipelineRetryPolicy.swift
  - host-mac/Tests/
  - backlog/tasks/T-335-host-pipeline-stop-join.md
---

## Amaç

Astra xhigh incelemesi (2026-10-10, `docs/reviews/2026-10-10/astra-review.md`, bulgu 3 ve 4). İkisini de orkestratör doğruladı.

1. **Stop yarışı (P2).**
   - `fail()` → `stop()` durumu hemen `stopped` yapar. Teardown capture + encoder için 3+3 sn'ye kadar sürebilir (`stopStepTimeout`).
   - Bu sırada `restartPipeline` (ör. ayar değişikliği) `stopKeepingDisplay()` çağırır. Durum zaten `stopped` olduğu için çağrı hemen `nil` döner.
   - Sonra `createPipeline(reusing: nil)` eski ekran hâlâ yaşarken aynı vendor/product/serial ile yeni bir ekran açmayı dener. Bu başarısız olur.
2. **Hata zamanı (P3).**
   - `onPipelineFailed` içinde `failedAt` teardown **bittikten sonra** alınır (`StreamCoordinator.swift` ~817).
   - Sonuç: 8. sn'de düşüp 3 sn'de sökülen bir pipeline, `settleIfStable` (`successUs` 10 sn) tarafından "kararlı" sayılır.
   - Böylece hata geçmişi silinir; devre kesici ve HDR → SDR geri düşüşü atlanabilir.

## Kapsam

1. `VideoPipeline` içinde "teardown sürüyor" ile "teardown bitti" ayrılır.
   - Bütün stop çağıranları tek bir teardown işlemine katılır ve ekran sahipliği için kesin bir sonuç alır.
   - `stopKeepingDisplay`, sürmekte olan bir teardown'a denk gelirse onun bitmesini bekler. Ekran o teardown'da tutulduysa onu alır, bırakıldıysa `nil` döner.
   - `fail()` yolundaki hata ile restart yolundaki "ekranı koru" isteği çatışırsa davranış *Plan* bölümünde yazılır (T-200 ile çakışmamalı).
2. Hatanın ilk görüldüğü an (`HostClock.nowUs()`) teardown'dan **önce** alınır ve `onFailure` ile koordinatöre taşınır. Kararlılık hesabı bu ana göre yapılır.
3. Girdi bırakma yolu ve T-325 watchdog davranışı değişmez.

## Kabul

- Testler:
  - yavaş teardown sırasında çağrılan ikinci stop, ilk teardown bitene kadar döner mi;
  - kısa çalışıp yavaş sökülen pipeline hata geçmişini sıfırlamıyor mu (`PipelineRetryPolicy` ile sahte saat).
- `./scripts/check.sh` geçer.
- Codex `--high` incelemesi (oturum, pipeline ve ekran yaşam döngüsü).
- Cihaz testi gerekmez; regresyon için normal bağlan/kopar ve mod değiştirme yeterli.

## Plan

## Handoff

## Open questions
