---
id: T-095
title: Tablet — ses çalma (AudioTrack düşük gecikme, titreşim tamponu, saat kayması yeniden örnekleme, A/V hizalama)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-093]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/video/
  - client-android/app/src/main/res/
  - client-android/app/src/test/
  - backlog/tasks/T-095-client-audio-playout.md
---

## Amaç

Karar 0011 ve PROTOCOL §4 `0x30–0x32` (T-093 ile kod çözücüler hazır). Mac sesi tablette düşük gecikmeyle ve kesintisiz çalsın.

Tablet araştırması (orkestratör, 2026-10-01):
- **AudioTrack** `PERFORMANCE_MODE_LOW_LATENCY`, `ENCODING_PCM_16BIT`, 48 kHz stereo (yerel hızla aynı olmalı, yoksa FAST yol kaybolur). `USAGE_MEDIA`/`CONTENT_TYPE_MOVIE`; FAST verilmezse `USAGE_GAME` dene.
- **Tampon:** `setBufferSizeInFrames(2×burst)`. `underrunCount` artarsa bir burst büyüt, en çok 6.
- **Yazıcı iş parçacığı:** `THREAD_PRIORITY_URGENT_AUDIO`, `WRITE_BLOCKING`, her çağrıda bir burst. Ağ iş parçacığı yalnızca halkayı doldurur.
- `setPlaybackParams` ile kayma düzeltme yok; FAST izlerde reddediliyor.

## Kabul kriterleri

- [ ] **HELLO ve tercih:**
  - HELLO `capabilities` bit8 `AUDIO_PCM` artık gönderilir.
  - ACCEPTED sonrası ve ayar değişince `AUDIO_PREFS`. Ses ayarı varsayılan açık, kalıcı (`shared_prefs`), bağlantı panelinde basit bir "Ses" anahtarı.
  - `--ez audio false` deney düğmesi.
- [ ] **`AudioJitterBuffer`** (saf):
  - Önceden ayrılmış ~300 ms `ShortArray` halka ve `(yazılan kare, capture_us)` çapa halkası.
  - `sample_index` boşluğu sessizlikle dolar. Taşma: en eski atılır, kısa sönümle.
  - Yeni `stream_id` ya da `STOPPED`: sıfırla.
- [ ] **`DriftController`** (saf):
  - 1–2 s penceredeki tampon seviyesinin tabanını hedefe (~5 ms güvenlik payı) tutar.
  - Alt taşmada hedefe hemen yeniden dolar. Fazlalığı yeniden örnekleme oranıyla yavaşça eritir: normalde ±%0,1, hedefin 20 ms üstündeyken ±%0,5.
  - 120 ms üstünde sert yeniden eşitleme: sön, atla, aç.
- [ ] **`CubicResampler`** (saf): 4 noktalı Hermite, oran 1'e çok yakın.
- [ ] **`AudioRamp`** (saf): alt taşmada 3 ms sönüş + sessizlik, yeniden başlarken 5 ms açılış. Tıklama yok.
- [ ] **`AudioPlayout`** (Android):
  - AudioTrack ömrü ve yazıcı iş parçacığı.
  - `getTimestamp` ile çalma konumu. `ERROR_DEAD_OBJECT` ve yönlendirme değişiminde (`addOnRoutingChangedListener`) izi yeniden kurar.
  - `ACTION_AUDIO_BECOMING_NOISY`'de sessizlik yazar.
  - Ses odağı (focus) istenmez; tabletin kendi medyası çalmaya devam eder.
  - Oturum sonu, arka plan ya da `AUDIO_CONFIG(STOPPED)`: `pause`/`flush`/`release`, halka boşalır.
- [ ] **A/V hizalama:**
  - Çalma gecikmesi `capture_us`'den (ClockSync ile) hesaplanır.
  - Ses video sunum gecikmesinden (pacer) **en çok 10 ms erken** olabilir; hedef ≤ 40 ms geç.
  - Video asla sese göre geciktirilmez.
  - Log: `av_offset_ms`.
- [ ] **Log** `MB/audio`, saniyede bir, yalnızca çalarken:
  - `perf_mode`, `burst`, `buf_frames`;
  - `level_ms_floor`, `ratio_ppm`, `underruns`, `drops`, `gaps`;
  - `av_offset_ms`.
  - Açılışta bir kez: `AudioManager` yerel hız/burst, `FEATURE_AUDIO_LOW_LATENCY`, verilen `performanceMode`.
  - Ses içeriği asla loglanmaz.
- [ ] Girdi ve video yolları değişmez; ses hatası oturumu düşürmez.
- [ ] Saf sınıflar JVM birim testli: boşluk doldurma, taşma, kayma, PI denetleyici yakınsaması (sentetik ±200 ppm saat), yeniden örnekleyici (sinüs, düşük bozulma), rampa.
- [ ] `./scripts/check.sh` geçiyor. adb kullanılmaz (cihaz testi orkestratörde).

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

