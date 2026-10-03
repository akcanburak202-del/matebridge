---
id: T-211
title: Game modes use the adaptive pacer by default (decision 0014 §2 amended)
status: in-progress
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

- [ ] [JVM] Oyun 120 / Oyun 60'a girişte `bufferFrames == BUFFER_ADAPTIVE`, kaynak `mode`; `--ez dev true --ei jitter 0` → 0 (`jitter_src=extra`).
- [ ] [JVM] Oyun modundan çıkış ve yeniden giriş tamponu doğru değere taşır (oturum katmanı kuralları, 0014 §3, değişmez).
- [ ] [doc] `docs/KNOBS.md` satır 1 varsayılanı: "Oyun modları da uyarlamalı (0014 §2, 2026-10-04)".
- [ ] [device] Oyun 60 + dokunma: `ev=game_mode … jitter=adaptive`, `phase_lock=1`, `skip_pct` ortanca ≤ %2.

## Plan

1. `GameJitter.choose`: `game -> Choice(VideoRenderer.BUFFER_ADAPTIVE, Source.MODE)`; sabit açılış değeri (`fixed != null`) önce gelir, değişmez. KDoc 0014 §2 (2026-10-04) olarak güncellenir. `MainActivity` değişmez: `currentJitter()` → `bufferFrames` → hem renderer hem `ev=profile pacer=` aynı değeri okur.
2. `GameModeTest`: oyun girişinde (Oyun 120, Oyun 60) `BUFFER_ADAPTIVE` + `mode`; `jitter 0` (EXTRA) oyunda 0 ve `jitter_src=extra`; çıkış/yeniden giriş tamponu taşır; log satırı `jitter=adaptive` (jitter_src yok).
3. `docs/KNOBS.md` satır 1 varsayılan sütunu: "Oyun modları da uyarlamalı (0014 §2, 2026-10-04)"; `--ei jitter 0` oyunda eski tampon 0 A/B'si.
4. `./scripts/check.sh`, handoff, `status: review`.

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulananlar:**
- **Açık sorular:**
