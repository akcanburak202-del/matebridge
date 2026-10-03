---
id: T-211
title: Game modes use the adaptive pacer by default (decision 0014 §2 amended)
status: done
phase: 6
owner: android-client-dev
depends_on: [T-208, T-210]
decisions: [0014]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - docs/KNOBS.md
  - backlog/tasks/T-211-client-game-mode-adaptive-default.md
---

## Amaç

Karar 0014 §2 2026-10-04'te değişti (kullanıcı onayı): oyun modlarında video tamponu 0 yerine uyarlamalı (`BUFFER_ADAPTIVE`). Ölçüm: `skip_pct` %10 → %0, +5 ms yakalama→bırakma, kullanıcı gecikme farkını hissetmedi (decision 0014 "Değişiklik", docs/NOTES.md 2026-10-04).

## Bağlam

- `GameJitter.choose(launch, fixed, game)`: bugün `game -> Choice(0, Source.MODE)`. Yeni: `game -> Choice(BUFFER_ADAPTIVE, Source.MODE)`; sabit açılış değeri (`--ez dev true --ei jitter 0|1|2|-1`) yine kazanır.
- `ev=game_mode … jitter=adaptive` (kaynak `mode`, `jitter_src` alanı yok) ve `ev=profile … pacer=adaptive`.

## Kapsam dışı

- `AdaptivePacer` değişikliği, diğer oyun modu varsayılanları (bit hızı, ses, kalem).

## Kabul kriterleri

- [x] [JVM] Oyun 120 / Oyun 60'a girişte `bufferFrames == BUFFER_ADAPTIVE`, kaynak `mode`; `--ez dev true --ei jitter 0` → 0 (`jitter_src=extra`).
- [x] [JVM] Oyun modundan çıkış ve yeniden giriş tamponu doğru değere taşır (oturum katmanı kuralları, 0014 §3, değişmez).
- [x] [doc] `docs/KNOBS.md` satır 1 varsayılanı: "Oyun modları da uyarlamalı (0014 §2, 2026-10-04)".
- [ ] [device] Oyun 60 + dokunma: `ev=game_mode … jitter=adaptive`, `phase_lock=1`, `skip_pct` ortanca ≤ %2.

## Plan

1. `GameJitter.choose`: `game -> Choice(VideoRenderer.BUFFER_ADAPTIVE, Source.MODE)`; sabit açılış değeri (`fixed != null`) önce gelir, değişmez. KDoc 0014 §2 (2026-10-04) olarak güncellenir. `MainActivity` değişmez: `currentJitter()` → `bufferFrames` → hem renderer hem `ev=profile pacer=` aynı değeri okur.
2. `GameModeTest`: oyun girişinde (Oyun 120, Oyun 60) `BUFFER_ADAPTIVE` + `mode`; `jitter 0` (EXTRA) oyunda 0 ve `jitter_src=extra`; çıkış/yeniden giriş tamponu taşır; log satırı `jitter=adaptive` (jitter_src yok).
3. `docs/KNOBS.md` satır 1 varsayılan sütunu: "Oyun modları da uyarlamalı (0014 §2, 2026-10-04)"; `--ei jitter 0` oyunda eski tampon 0 A/B'si.
4. `./scripts/check.sh`, handoff, `status: review`.

## Handoff

- **Commit:** `41afceb` (uygulama; plan `45b9c42`), dal `task/T-211-client-game-mode-adaptive-default`. `./scripts/check.sh` → ALL OK (GameModeTest 15/15).
- **Dokunulan dosyalar:**
  - `client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt`: `GameJitter.choose` oyunda `Choice(BUFFER_ADAPTIVE, MODE)`; KDoc 0014 §2 (2026-10-04).
  - `client-android/app/src/test/kotlin/dev/matebridge/client/stream/GameModeTest.kt`: `jitterIsAdaptiveInGameModesFromTheMode` (Oyun 120/60 girişi + `ev=game_mode` alanları), `jitterSurvivesExitAndReentry` (kaynak `mode` ve `jitter 0` EXTRA için çıkış/yeniden giriş), `launchJitterZeroGivesTheOldGameBuffer` (`jitter=0 jitter_src=extra`); eski "0" testi yerine.
  - `docs/KNOBS.md` satır 1 (varsayılan sütunu + kart sütununa T-211).
- **Varsayımlar:** `MainActivity` değişmedi: `currentJitter()` → `bufferFrames` hem renderer'a hem `ev=profile pacer=` alanına gidiyor (`DevKnobs.kt:204`), dolayısıyla oyun modunda `pacer=adaptive` kendiliğinden çıkar. Açılış değeri yoksa `launchBufferFrames` zaten `BUFFER_ADAPTIVE`; yani oyun/diğer mod ayrımı artık yalnızca `game_mode` satırındaki etikette fark eder, renderer'a giden tampon her modda aynı.
- **Test edilmeyenler / cihazda doğrulananlar:** Cihaz kriteri açık. Tablette: (1) normal açılış (dev yok), Oyun 60'a geç, dokunarak oyna → logcat `ev=game_mode action=enter … jitter=adaptive` (`jitter_src` yok) ve `ev=profile … pacer=adaptive`; (2) stats satırlarında `phase_lock=1`, `skip_pct` ortanca ≤ %2; (3) Oyun 120 girişinde de `jitter=adaptive`; (4) Akıcı'ya çıkış → `action=exit … jitter=adaptive`; (5) A/B: `--ez dev true --ei jitter 0` ile açılış → oyunda `jitter=0 jitter_src=extra`.
- **Açık sorular:** `StreamMode.kt` KDoc'ları (satır 15 ve 21) hâlâ "jitter buffer 0" diyor; dosya kartın `files:` listesinde olmadığı için değiştirilmedi. Küçük bir yorum düzeltmesi olarak orkestratör ya da sonraki bir kart güncelleyebilir.
