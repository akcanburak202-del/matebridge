---
id: T-381
title: İstemci — geliştirici anahtarı `audio_out=shared` (Düşük gecikme'de AAudio SHARED ile başla) — exclusive MMAP cızırtısı A/B
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-381-client-aaudio-shared-knob.md
---

## Amaç

NOTES 2026-10-25 23:40: Düşük gecikme (`api=aaudio sharing=exclusive mmap=1 burst=240 buf=1440`) ~8 dk sonra cızırdamaya başlıyor, uygulama sayaçları temiz; akışı yeniden açmak (Uyumlu → Düşük gecikme) gideriyor. Hipotez: exclusive MMAP akışı uygulamaya görünmeyen bir duruma giriyor. A/B için Düşük gecikme zincirini (0012: EXCLUSIVE → SHARED → TRACK) **SHARED adımından** başlatan bir geliştirici anahtarı. Varsayılan davranış değişmez.

## Kabul

1. `--ez dev true --es audio_out shared` (mevcut `audio_out` anahtarına yeni değer; `DevKnobs.SPECS` `ids`) → AAudio önce SHARED açılır. MMAP'lı ya da MMAP'sız SHARED kabul edilir mi, mevcut SHARED gecikme denetimi (probation) uygulanır mı: Plan'da kararlaştır ve gerekçelendir; amaç ölçüm, yani anahtar açıkken SHARED akışı mümkünse korunmalı (gecikme `audio_out`/`audio_clock_raw` satırlarında görünür).
2. Anahtar yokken davranış bayt bayt aynı (mevcut testler yeşil). Panel `Ses çıkışı` seçimi değişmez; anahtar yalnız Düşük gecikme (auto/aaudio) yolunu etkiler, Uyumlu seçiliyken yok sayılır.
3. `audio ev=audio_out` satırında `reason=` ile anahtarın etkisi görünür (`sharing=shared mmap=0|1`, `requested=shared`). `diag ev=dev_knobs` profil listesinde görünür.
4. Daily APK'da çalışır (geliştirici kapısı derleme türünden bağımsız).
5. Birim testleri: SinkPolicy zinciri anahtarla SHARED'dan başlar, SHARED açılamazsa TRACK'e düşer; anahtarsız zincir değişmez.
6. `docs/KNOBS.md` (`audio_out` satırı) ve gerekiyorsa `docs/LOGGING.md` güncellenir.

## Plan

## Handoff

## Open questions
