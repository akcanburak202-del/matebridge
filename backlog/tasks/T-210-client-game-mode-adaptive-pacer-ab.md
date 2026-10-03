---
id: T-210
title: Let the dev jitter knob select the adaptive pacer in game modes (A/B for T-208)
status: review
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

- [x] [JVM] `--ez dev true --ei jitter -1` → oyun modunda `bufferFrames = BUFFER_ADAPTIVE`, `jitter_src=extra`, etiket `adaptive`; `dev` olmadan yok sayılır (`ignored=jitter`).
- [x] [JVM] `-2` ve `3` gibi geçersiz değerler bugünkü gibi sınırlanır; `0..2` değişmez.
- [x] [doc] `docs/KNOBS.md` satır 1: `-1` = uyarlamalı (oyun modunda A/B için).
- [ ] [device] Oyun 60 + dokunma (panel 120 Hz), `--ez dev true --ei jitter -1 --ez pace_trace true --ez stats_1s true`: `phase_lock=1`, `sim.py --holds` 120 Hz cadence 2 exact ≥ %98, kullanıcı hissi; yakalama→bırakma p50 farkı ölçülür.

## Plan

1. `DevKnobs.parse`: `jitter` değeri `-1` (`BUFFER_ADAPTIVE`) ise olduğu gibi kalır; diğer değerler bugünkü gibi `coerceIn(0, 2)` (`-2` → 0, `3` → 2). Kapı (`dev`) değişmez: `dev` yoksa `jitter` null + `ignored=jitter`.
2. `MainActivity` değişmez: `bufferFrames = devKnobs.jitter ?: BUFFER_ADAPTIVE`, `bufferFixedBy = EXTRA` (jitter null değilse) zaten `-1`'i `GameJitter.choose` içinde `Choice(-1, EXTRA)` olarak taşır → `jitter=adaptive jitter_src=extra`, `pacer=adaptive`.
3. `GameMode.kt`: yalnız KDoc (davranış aynı).
4. Testler: `DevKnobsTest` (-1 korunur, -2/3 sınırlanır, 0..2 aynı, dev'siz yok sayılır); `GameModeTest` (oyun modunda `choose(-1, EXTRA, game=true)` → adaptive/extra ve log satırı).
5. `docs/KNOBS.md` satır 1.

## Handoff

- **Commit:** `95bc1d4` (uygulama; plan `3171c76`), dal `task/T-210-client-game-mode-adaptive-pacer-ab`. `./scripts/check.sh` → ALL OK.
- **Dokunulan dosyalar:** `DevKnobs.kt` (`JITTER_ADAPTIVE = -1`, `jitter(v)`: -1 korunur, diğerleri `coerceIn(0, 2)`), `GameMode.kt` (yalnız KDoc), `DevKnobsTest.kt`, `stream/GameModeTest.kt`, `docs/KNOBS.md` satır 1, bu kart.
- **Varsayımlar:** `MainActivity` değişmedi: `bufferFrames = devKnobs.jitter ?: BUFFER_ADAPTIVE` ve `bufferFixedBy = EXTRA` (jitter null değilse) zaten `-1`'i `GameJitter.choose` → `Choice(-1, EXTRA)` olarak taşıyor; `ev=profile` `pacer=adaptive` (`bufferFrames < 0`) ve `knobs=jitter:-1`. Oyun dışı modda `--ei jitter -1` varsayılanla aynı davranır, yalnız `jitter_src=extra` görünür. Varsayılan (bayraksız) davranış aynı: oyun modu 0.
- **Test edilmeyenler / cihazda doğrulananlar:** Cihaz testi yapılmadı. Tablette: Oyun 60 + dokunma, panel 120 Hz, `am start … --ez dev true --ei jitter -1 --ez pace_trace true --ez stats_1s true`. Beklenen: `diag ev=dev_knobs dev=1 ignored=-`; `ev=profile … pacer=adaptive … knobs=jitter:-1;stats_1s:1;pace_trace:1`; `ev=game_mode action=enter … jitter=adaptive jitter_src=extra`; pace trace'te `path` artık `none` değil ve `phase_lock=1`; `sim.py --holds` 120 Hz cadence 2 exact ≥ %98; `skip_pct` ve yakalama→bırakma p50, jitter'sız (0) koşuyla karşılaştırılır; kullanıcı hissi. Ayrıca `dev` olmadan `--ei jitter -1` → `ignored=jitter`, oyun modu `jitter=0`.
- **Açık sorular:** Yok.
