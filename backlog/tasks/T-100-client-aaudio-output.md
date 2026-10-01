---
id: T-100
title: Tablet — ses çıkışı AAudio MMAP (NDK/C++), AudioTrack'e otomatik geri dönüş
status: todo
phase: 5
owner: android-client-dev
depends_on: [T-098, T-099]
decisions: [0011, 0012]
files:
  - client-android/app/src/main/cpp/
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - client-android/app/build.gradle.kts
  - client-android/AGENTS.md
  - README.md
  - backlog/tasks/T-100-client-aaudio-output.md
---

## Amaç

Karar 0012. T-099 sondası `probes/aaudio-probe/` içinde çalışan AAudio kodunu içeriyor (`app/src/main/cpp/aaprobe.cpp`); oradan örnek alın. Ölçüm: EXCLUSIVE MMAP ~13 ms, AudioTrack ~99 ms.

## Kabul kriterleri

- [ ] `cpp/` altında küçük bir AAudio sarmalayıcı (JNI):
  - aç: 48 kHz, s16 stereo, `LOW_LATENCY`, istenen paylaşım;
  - başlat, durdur, kapat;
  - `framesPerBurst`, `bufferSize`;
  - `getTimestamp(CLOCK_MONOTONIC)`;
  - xrun sayısı;
  - verilen paylaşım ve MMAP durumu.
  - Veri yolu, karar 0012 madde 3'e uygun (tahsis ve kilit yok). Seçilen yöntem Plan'da gerekçelendirilir.
- [ ] `AudioPlayout`'a çıkış soyutlaması (`AudioSink`: AudioTrack | AAudio).
  - Mevcut `PlayoutCore` (titreşim tamponu, kayma, rampa, A/V) değişmeden iki çıkışla çalışır.
  - Çalma konumu ve gecikme her iki çıkıştan aynı biçimde alınır; A/V hesabı ve `audio_ms` doğru kalır.
- [ ] Seçim sırası karar 0012 madde 2'deki gibi. `--es audio_out aaudio|track` anahtarı.
- [ ] Log, açılışta ve yeniden kurulumda: `ev=audio_out api=aaudio|track sharing=… mmap=… burst=… buf=…`. Stats satırında `api=` ve `xruns=`.
- [ ] `AAUDIO_ERROR_DISCONNECTED` ve yönlendirme değişiminde akış yeniden açılır. Üst üste başarısızlıkta AudioTrack'e düşülür ve oturum etkilenmez.
- [ ] Yaşam döngüsü (durdur/arka plan/oturum sonu/yeni `stream_id`) T-095/T-098 kurallarıyla aynı; tek seferlik kapatma.
- [ ] `build.gradle.kts`: `ndkVersion = "30.0.16248370"`, `externalNativeBuild` CMake 4.1.2, yalnızca `arm64-v8a` (tablet). `client-android/AGENTS.md` ve `README.md`'ye NDK ve CMake gereksinimi notu.
- [ ] Saf Kotlin parçaları (seçim ve geri dönüş karar makinesi, konum ve gecikme hesabı) JVM testli. C++ kısmı derleniyor.
- [ ] `./scripts/check.sh` geçiyor. adb kullanılmaz (cihaz testi orkestratörde).

## Plan

(ajan doldurur, commit eder, sonra uygular)

## Handoff

