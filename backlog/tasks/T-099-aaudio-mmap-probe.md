---
id: T-099
title: Sonda — AAudio MMAP tablette var mı, çıkış gecikmesi AudioTrack'e göre ne kadar düşük (NDK kurulumu dahil)
status: in_progress
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

1. **Araç seti:** Google'ın resmi `commandlinetools-mac-*_latest.zip` dosyası `~/Library/Android/sdk/cmdline-tools/latest/` altına açılır. `sdkmanager --list` ile güncel kararlı `ndk;X` ve `cmake;Y` seçilip kurulur. Yalnızca gereken standart SDK lisansı kabul edilir. Başka sistem geneli kurulum yapılmaz.
2. **Proje iskeleti:** `probes/input-probe` kopyası (AGP 9.4.1, Gradle 9.8.0 wrapper, compileSdk 37, minSdk 29, targetSdk 31, AGP yerleşik Kotlin). Paket ve namespace kartta istendiği gibi `dev.matebridge.aaudioprobe`. Gradle'da `ndkVersion` sabitlenir, `externalNativeBuild { cmake }` kullanılır, ABI yalnızca `arm64-v8a`. Bağımlılık eklenmez; yalnızca test için `junit`.
3. **Native (`app/src/main/cpp/aaprobe.cpp`, `-laaudio -llog -ldl`):** tek bir JNI çağrısı `runAaudio(sharing, durationMs, amplitude)`.
   - İstek: LOW_LATENCY, 48 kHz, I16, 2 kanal, `USAGE_MEDIA`. Ton −40 dBFS (genlik 0,01) 1 kHz.
   - Bloklayan yazma, burst burst. `bufferSize = 2×burst` (ürünün `START_BURSTS`'ü) ile başlar; xrun artarsa bir burst büyür (üst sınır kapasite).
   - Her yazmadan sonra `AAudioStream_getTimestamp(CLOCK_MONOTONIC)` ile `(framesWritten, framePosition, timeNs, nowNs)` dörtlüsü kaydedilir. İlk 500 ms ısınma atlanır.
   - `AAudioStream_isMMapUsed`, `dlopen("libaaudio.so")` + `dlsym` ile çağrılır. Bulunamazsa `-1` (bilinmiyor) yazılır.
   - Sonuç `LongArray` olarak döner: başlık (gerçek paylaşım ve performans modu, mmap, burst, kapasite, ilk ve son bufferSize, hız, kanal, biçim, xrun, hata kodu) + örnekler.
   - Durdurma bayrağı (`std::atomic`) `onPause`'da kurulur; akış her durumda kapatılır.
4. **AudioTrack (Kotlin):** ürünün `buildTrack` ayarıyla aynı (`USAGE_MEDIA`, `CONTENT_TYPE_MOVIE`, 48 kHz s16 stereo, `PERFORMANCE_MODE_LOW_LATENCY`, `MODE_STREAM`). Burst `PROPERTY_OUTPUT_FRAMES_PER_BUFFER`'dan alınır; başlangıç `2×burst`, alt taşmada +1 burst. `getTimestamp(AudioTimestamp)` (monotonik) ile aynı dörtlü kaydedilir.
5. **Saf Kotlin (JVM testli):**
   - `LatencyMath.latencyMs(written, presented, presNs, nowNs, rate)` = `(written − presented)/rate − (now − presNs)`. Bu Oboe `calculateLatencyMillis` ile aynı formüldür. Kartta `+ (şimdi − sunum)` yazıyor, ama sunum zamanı geçmişte olduğu için o süre kadar kare zaten çalınmıştır; doğru işaret eksidir.
   - `LatencyStats` (sayı, ortalama, p50, p95, min, maks).
   - `NativeResult.parse(LongArray)`.
6. **Etkinlik:** `onResume`'da üç ölçüm sırayla bir iş parçacığında yapılır: (a) EXCLUSIVE, (b) SHARED, (c) AudioTrack. Her biri ~5 s, aralarında 1 s boşluk.
   - Sonuçlar `MB/aaprobe` logcat satırlarına (LOGGING.md biçimi, `ev=result ...`) ve ekrandaki tek aralıklı tabloya yazılır.
   - `onPause` durdurma ister ve iş parçacığını bekler. Arka planda ses çalmaz. "Tekrar" düğmesi yeniden çalıştırır.
7. **Doküman:** `probes/README.md` tablosuna satır eklenir. `gradlew assembleDebug testDebugUnitTest` ve `./scripts/check.sh` çalıştırılır, Handoff doldurulur.

## Handoff

