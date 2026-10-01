---
id: T-101
title: Tablet — panelde "Ses çıkışı" seçeneği (Düşük gecikme / Uyumlu) ve AAudio gecikme ölçümü düzeltmesi
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-100, T-096]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/
  - client-android/app/src/test/
  - backlog/tasks/T-101-client-audio-output-setting.md
---

## Amaç

NOTES 2026-10-01 ~22:15.

1. Kullanıcı eski ses yoluna (AudioTrack) kolayca geçebilmek istiyor. Bugün bu yalnızca `--es audio_out track` ile mümkün.
2. AAudio yolunda `audio_ms` ~470 ve `av_offset_ms` ~430 gösteriyor. Seviye 8–9 ms, çıkış ~13 ms; gerçek değer ~35–45 ms olmalı. OutputClock, AAudio `getTimestamp` `framePosition`'ını yazılan kare sayacıyla yanlış eşliyor (MMAP start catch-up, `preFrames` ya da çıkış başlangıç ofseti). AudioTrack yolunda değerler makuldü (~170–190 ms).

## Kabul kriterleri

- [ ] Bağlantı paneline "Ses çıkışı" seçeneği: **Düşük gecikme** (AAudio MMAP, varsayılan) / **Uyumlu** (AudioTrack).
  - Kalıcı (`shared_prefs`). `--es audio_out` ek parametresi kalıcı ayarı ezer ama kaydetmez.
  - Akış sırasında panel gizli olduğundan değişiklik bir sonraki ses akışında ya da yeniden bağlantıda uygulanır. Panel görünürken değiştirilirse ve akış varsa hemen yeniden açılır.
  - Log: `ev=audio_out_pref value=…`.
- [ ] AAudio için OutputClock düzeltmesi.
  - Ham değerler bir kez debug log'a yazılır: `framesWritten`, `framesRead`, `timestamp.framePosition`, `timestamp.time`, `now`.
  - Bunlarla kök neden bulunur ve Handoff'a yazılır. Çalma konumu AAudio'nun kendi sayaçlarıyla (`getFramesWritten`/`getFramesRead` ya da zaman damgası) aynı alanda hesaplanır.
  - Test: sentetik AAudio sayaçlarıyla (başlangıçta okuyucunun yazıcıdan önde başladığı catch-up durumu dahil) gecikme ≈ tampon + donanım gecikmesi çıkar.
- [ ] AudioTrack yolunun davranışı ve değerleri değişmez.
- [ ] `./scripts/check.sh` geçiyor. adb kullanılmaz.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

