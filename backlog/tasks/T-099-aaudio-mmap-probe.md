---
id: T-099
title: Sonda — AAudio MMAP tablette var mı, çıkış gecikmesi AudioTrack'e göre ne kadar düşük (NDK kurulumu dahil)
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-095]
decisions: [0011]
files:
  - probes/aaudio-probe/
  - probes/README.md
  - backlog/tasks/T-099-aaudio-mmap-probe.md
---

## Amaç

T-097 madde 3:
- Tablette yalnızca 20 ms'lik MIXER çıkışı var (`AudioOut_D`, HAL 960 kare, FastMixer yok). AudioTrack `perf_mode=none`.
- `aaudio.mmap_policy=2`, `aaudio.mmap_exclusive_policy=2`: AAudio MMAP yolu var olabilir.
- Kullanıcı onayı (2026-10-01): NDK kurulup ölçülsün, karar sonra.

## Kabul kriterleri

- [ ] **Araç seti:** Android SDK'ya (`~/Library/Android/sdk`) `cmdline-tools` (yoksa Google'dan resmi zip) ve `sdkmanager` ile güncel kararlı NDK + CMake kurulur. JDK: `scripts/check.sh`'deki gibi Android Studio JBR. Kurulan sürümler Handoff'a yazılır.
- [ ] **`probes/aaudio-probe/`:** bağımsız küçük bir Android projesi (`probes/input-probe` kalıbı). Paket `dev.matebridge.aaudioprobe`; ürün uygulamasına dokunmaz. C++ (AAudio) + Kotlin.
  - Açılınca sırayla üç ölçüm yapar, her biri ~5 s, **çok düşük genlikli** (−40 dBFS) 1 kHz ton ya da sessizlik çalar:
    - (a) AAudio `AAUDIO_PERFORMANCE_MODE_LOW_LATENCY` + `AAUDIO_SHARING_MODE_EXCLUSIVE`;
    - (b) AAudio LOW_LATENCY + SHARED;
    - (c) Java AudioTrack, ürünle aynı ayar (`PERFORMANCE_MODE_LOW_LATENCY`, 48 kHz s16 stereo, `USAGE_MEDIA`).
  - Her biri için logcat `MB/aaprobe` satırları:
    - verilen paylaşım ve performans modu;
    - MMAP kullanılıyor mu (`AAudioStream_isMMapUsed` NDK'da yoksa: `dlsym` ile ya da `dumpsys media.aaudio` / `audio_flinger` "mmap" çıktısıyla dolaylı);
    - `framesPerBurst`, `bufferCapacity`, `bufferSize`, örnekleme hızı;
    - xrun sayısı;
    - **çıkış gecikmesi tahmini:** `getTimestamp(CLOCK_MONOTONIC)` ile `(yazılan kare − sunulan kare) / hız + (şimdi − sunum zamanı)` ortalaması ve p95.
  - Ekranda da özet tablo gösterir.
  - Bitince akışları kapatır; arka planda ses çalmaz.
- [ ] Derleme: `probes/aaudio-probe/gradlew assembleDebug` çalışır. `./scripts/check.sh` etkilenmez (sonda check'e eklenmez).
- [ ] `probes/README.md` tablosuna satır eklenir.
- [ ] adb **kullanılmaz** (kurulum ve ölçüm orkestratörde). Handoff'a çalıştırma komutları ve beklenen log satırları yazılır.

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

