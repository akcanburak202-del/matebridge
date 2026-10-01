---
id: T-098
title: Tablet — ses: sessizlik aralarını alt taşma saymamak, ses başlangıcında hızlı çalma, AudioTrack tamponu 1920 → 960
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-095]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - backlog/tasks/T-098-client-audio-silence-buffer.md
---

## Amaç

T-097'nin ilk iki maddesi. NOTES 2026-10-01 ~20:50:
- Ses ~170–190 ms, video ~51 ms.
- Host'ta Mac ses çalmazken tap IO'su duruyor; o aralıkta `AUDIO_FRAME` gelmiyor. Tablet bunu alt taşma sayıyor (`underruns` 2–3), `safety_ms` 5 → 20 büyüyor ve sonraki seslerde gecikme artıyor.
- AudioTrack `buf_frames=1920` (2 × 960 burst); çıkış HAL'i 960 kare (20 ms), `perf_mode=none`.

Kullanıcı gecikmeyi göze batan bulmadı. Amaç, düşük riskli kazançlar.

## Kabul kriterleri

- [ ] **Sessizlik ayrımı.**
  - Tampon boşaldığında yeni paket gelmiyorsa ve son paketten beri ≥ ~2 paket süresi (20 ms) geçtiyse durum "kaynak sessiz" (`idle`) sayılır: sönüşle sessizlik yazılır, `underruns` ve güvenlik payı **artmaz**. Ayrı sayaç `idle_gaps`.
  - Gerçek alt taşma (paketler akarken tamponun bitmesi) bugünkü gibi sayılır.
  - Sessizlikten sonra ilk paket: kısa açılışla (≤ 5 ms) **hedef seviye** kadar dolunca hemen çalar. Uzun hazırlık yok; A/V hedefi PRIMING kuralıyla uyumlu kalır.
  - `sample_index` sıçraması (host IO durup yeniden başlayınca) sessizlik olarak işlenir. Eski boşluk sessizlikle doldurulup gecikme biriktirilmez: büyük sıçramada tampon sıfırlanır ve yeni noktadan başlanır.
- [ ] **Tampon boyu.**
  - Başlangıç `setBufferSizeInFrames(1 × burst)` (960). Gerçek track alt taşmasında bugünkü gibi bir burst büyür (en çok 6).
  - Deney anahtarı `--ei audio_buf_bursts N` (1–6, varsayılan 1); açılışta log'a yazılır.
- [ ] Log `MB/audio` stats'a `idle_gaps` eklenir. Diğer alanlar korunur.
- [ ] Testler:
  - Kesik kesik ses simülasyonu (100 ms ses, 500 ms sessizlik, tekrar): `underruns` ve `safety_ms` artmaz, her ses başlangıcında çalma gecikmesi hedef + açılış süresinden fazla değil.
  - Gerçek ağ kesintisi simülasyonu: `underruns` artar.
  - `sample_index` sıçraması.
- [ ] `./scripts/check.sh` geçiyor. adb kullanılmaz.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

