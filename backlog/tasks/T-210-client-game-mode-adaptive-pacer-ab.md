---
id: T-210
title: Let the dev jitter knob select the adaptive pacer in game modes (A/B for T-208)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-208, T-185]
decisions: [0014, 0026]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt   # only if the launch value path needs it
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - docs/KNOBS.md
  - backlog/tasks/T-210-client-game-mode-adaptive-pacer-ab.md
---

## Amaç

Cihaz 2026-10-04 ~01:47 (T-208 sonrası oyun ölçümü): oyun modlarında (karar 0014 §2) video tamponu 0 → `FramePacer` kareyi çözülür çözülmez bırakıyor, `AdaptivePacer` (ve T-208'in 2:1 kilidi) hiç çalışmıyor: pace trace'te 20 000 karenin hepsi `queued`/`path=none`, `phase_lock=0`; `skip_pct` ortanca %10 (öncekiyle aynı), kullanıcı "hâlâ takılma var". T-208'in faydasını oyunda ölçebilmek için oyun modunda uyarlamalı zamanlayıcıyı seçmenin bir yolu gerekiyor. Bugün `--ei jitter` `coerceIn(0, 2)` ile sınırlı (`DevKnobs.kt:129`), `-1` (`BUFFER_ADAPTIVE`) 0'a dönüyor.

## Bağlam

- `GameJitter.choose(launch, fixed, game)`: sabit açılış değeri her zaman kazanır. `-1` = `VideoRenderer.BUFFER_ADAPTIVE`.
- Varsayılan davranış değişmez (oyun modu yine 0). Bu kart yalnız A/B içindir; varsayılanın değişmesi ayrı bir karar (0014 §2) ve kullanıcı onayı ister.
- `ev=game_mode … jitter=adaptive jitter_src=extra` ve `ev=profile … pacer=adaptive` doğru yazılmalı.

## Kapsam dışı

- Oyun modu varsayılanını değiştirmek. `AdaptivePacer` değişikliği.

## Kabul kriterleri

- [ ] [JVM] `--ez dev true --ei jitter -1` → oyun modunda `bufferFrames = BUFFER_ADAPTIVE`, `jitter_src=extra`, etiket `adaptive`; `dev` olmadan yok sayılır (`ignored=jitter`).
- [ ] [JVM] `-2` ve `3` gibi geçersiz değerler bugünkü gibi sınırlanır; `0..2` değişmez.
- [ ] [doc] `docs/KNOBS.md` satır 1: `-1` = uyarlamalı (oyun modunda A/B için).
- [ ] [device] Oyun 60 + dokunma (panel 120 Hz), `--ez dev true --ei jitter -1 --ez pace_trace true --ez stats_1s true`: `phase_lock=1`, `sim.py --holds` 120 Hz cadence 2 exact ≥ %98, kullanıcı hissi; yakalama→bırakma p50 farkı ölçülür.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
