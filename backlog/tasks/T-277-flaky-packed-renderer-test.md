---
id: T-277
title: Client test — PackedRendererTest.directPathNeverCallsAHook ara sıra düşüyor (yarış)
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/test/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - backlog/tasks/T-277-flaky-packed-renderer-test.md
---

## Amaç

`./scripts/check.sh`'ta `PackedRendererTest.directPathNeverCallsAHook` (ve bazen bir başka Android testi) yaklaşık her 2–3 koşuda bir düşüyor, tekrarında geçiyor (2026-10-06 T-266, T-269, T-272, T-276 ve 0036 birleşiminde görüldü). Kök nedeni bul (test yarışı mı, üründe gerçek bir yarış mı) ve düzelt.

## Kabul

1. Testi döngüde (ör. 50 kez, `--tests` ile tek test) koşturup düşme oranını ölç; kök nedeni Handoff'a yaz.
2. Neden testteyse testi deterministik yap (gerçek zaman beklemesi / iş parçacığı sırası yerine senkronizasyon); neden üründeyse (üretim kodunda yarış) en küçük düzeltme + test. Ürün davranışı değişmeyecek.
3. Düzeltmeden sonra 50 koşuda 0 düşme; `./scripts/check.sh` ALL OK.

## Plan

(ajan doldurur)

## Handoff

## Open questions
