---
id: T-099
title: Sonda — AAudio MMAP tablette var mı, çıkış gecikmesi AudioTrack'e göre ne kadar düşük (NDK kurulumu dahil)
status: done
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


- **Commit:** `4aff31f` (uygulama). Plan `07bef30`'da. Bu Handoff ayrı commit'te.
- **Dal:** `task/T-099-aaudio-probe`.
- **`./scripts/check.sh`:** ALL OK (2026-10-01). Sondanın kendi testleri: `gradlew assembleDebug testDebugUnitTest`, 14 JVM testi geçti.

### Kurulan araç seti (`~/Library/Android/sdk`)

| Paket | Sürüm | Kaynak |
|---|---|---|
| `cmdline-tools;latest` | 23.0 (`commandlinetools-mac_arm64-16111833_latest.zip`) | dl.google.com. SHA-1 `ad03dc49…e830`, `repository2-3.xml` ile eşleşti. |
| `ndk;30.0.16248370` | r30, kararlı kanal | `sdkmanager` |
| `cmake;4.1.2` | kararlı kanal | `sdkmanager` |

- JDK: Android Studio JBR (Java 25.0.3).
- Yeni lisans kabul edilmedi. Mevcut `android-sdk-license` yetti; kurulum istem çıkmadan, `stdin=/dev/null` ile tamamlandı.
- Sistem genelinde başka bir şey kurulmadı.
- Not: `sdkmanager` kullanımdan kaldırıldığına dair uyarı basıyor ve yerine `android sdk` öneriyor. Yine de çalıştı.

### Dokunulan dosyalar

- `probes/aaudio-probe/`:
  - Gradle iskeleti ve wrapper (`input-probe` kopyası).
  - `app/build.gradle.kts`: `ndkVersion` + CMake 4.1.2, yalnızca `arm64-v8a`.
  - `AndroidManifest.xml`.
  - `cpp/CMakeLists.txt`, `cpp/aaprobe.cpp`.
  - Kotlin: `NativeProbe`, `Latency` (LatencyMath, LatencyStats), `ProbeResult` (+ NativeResult), `ResultFormat`, `ToneGen`, `AudioTrackRunner`, `ProbeActivity`.
  - Testler: `LatencyTest`, `NativeResultTest`, `ToneGenTest`.
- `probes/README.md`: tabloya bir satır eklendi.
- Bu kart.
- `client-android/` ve `host-mac/` dosyalarına dokunulmadı.

### Varsayımlar

- **Gecikme formülü:** `(yazılan − sunulan)/hız − (şimdi − sunum_zamanı)`, yani Oboe `calculateLatencyMillis` ile aynı. Kartta `+` yazıyordu, ama sunum zamanı geçmişte olduğu için o aradaki kareler zaten çalınmıştır; doğru işaret eksidir. Testler bu işareti doğruluyor.
- **Ölçülen şey:** "son yazılan karenin DAC'a ulaşmasına kalan süre". AAudio için, cihaz MMAP kullanıyorsa zaman damgası DSP'den, kullanmıyorsa AudioFlinger'dan gelir. Akustik ölçüm değildir.
- **Isınma:** ilk 500 ms atılır. Örnekler her yazmadan sonra alınır (en çok 16384).
- **Tampon:** her üç durumda da başlangıç `2×burst` (ürünün `START_BURSTS`'ü). xrun/underrun artınca +1 burst. AudioTrack için üst sınır ürünün 6 burst'ü değil, kapasitedir.
  - `buf_default` (açılıştaki), `buf_start` ve `buf_final` loglanır.
- **AAudio isteği:** 48 kHz, I16, 2 kanal, `USAGE_MEDIA`, `CONTENT_TYPE_MOVIE`. Uygulama tarafındaki biçim I16 değilse ölçüm `stage=format` ile hata verir.
- **MMAP tespiti:** `dlsym("AAudioStream_isMMapUsed")`. Sembol bulunamazsa `mmap=unknown` yazılır; o zaman aşağıdaki `dumpsys` çıktısına bakılmalı.
  - EXCLUSIVE istenip `sharing=shared` geldiyse cihaz ayrıcalıklı MMAP vermedi demektir.
- **Kalem kalem uyumsuzluklar:**
  - Düğme etiketi İngilizce "Run again"; Plan'da "Tekrar" yazıyordu.
  - Paket adı kartta istendiği gibi `dev.matebridge.aaudioprobe`. `client-android/AGENTS.md` ise probe paketleri için `dev.matebridge.probe.<name>` diyor.

### Tablette kontrol edilecekler (orkestratör, adb ile)

Komutlar repo kökünden çalıştırılır.

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
(cd probes/aaudio-probe && ./gradlew assembleDebug)
adb install -r probes/aaudio-probe/app/build/outputs/apk/debug/app-debug.apk
adb logcat -c
adb shell am start -n dev.matebridge.aaudioprobe/.ProbeActivity
# Zaman çizelgesi (başlangıçtan itibaren yaklaşık): a_excl 0–5 s, ara 1 s, b_shared 6–11 s, ara, c_track 12–17 s.
sleep 2.5; adb shell dumpsys media.aaudio > /tmp/aaprobe_dumpsys_a.txt        # a sırasında: MMAP akışı/servis
sleep 6;   adb shell dumpsys media.aaudio > /tmp/aaprobe_dumpsys_b.txt        # b sırasında
           adb shell dumpsys media.audio_flinger > /tmp/aaprobe_af_b.txt      # "mmap" / AAudio thread var mı
sleep 6;   adb shell dumpsys media.audio_flinger > /tmp/aaprobe_af_c.txt      # c sırasında: AudioTrack hangi thread'de
sleep 6;   adb logcat -d -s 'MB/aaprobe:*'
adb exec-out screencap -p > /tmp/aaprobe.png                                  # ekrandaki özet tablo
adb shell am force-stop dev.matebridge.aaudioprobe
grep -i -e mmap -e aaudio /tmp/aaprobe_dumpsys_a.txt /tmp/aaprobe_af_b.txt | head -40
```

Beklenen logcat satırları (değerler örnektir):

```text
<ms> I aaprobe sid=- gen=0 ev=run_start duration_ms=5000 gap_ms=1000 warmup_ms=500 amplitude=0.01
<ms> I aaprobe sid=- gen=0 ev=case_start case=a_excl
<ms> I aaprobe sid=- gen=0 ev=result case=a_excl api=aaudio req_sharing=exclusive sharing=exclusive|shared perf=low_latency|none mmap=yes|no|unknown rate=48000 ch=2 fmt=i16 burst=… capacity=… buf_default=… buf_start=… buf_final=… xruns=… frames_written=… ts_ok=… ts_fail=… lat_n=… lat_mean_ms=… lat_p50_ms=… lat_p95_ms=… lat_min_ms=… lat_max_ms=… err=0 stage=none
<ms> I aaprobe sid=- gen=0 ev=case_start case=b_shared
<ms> I aaprobe sid=- gen=0 ev=result case=b_shared api=aaudio …
<ms> I aaprobe sid=- gen=0 ev=case_start case=c_track
<ms> I aaprobe sid=- gen=0 ev=result case=c_track api=audiotrack req_sharing=n/a sharing=n/a perf=none|low_latency mmap=n/a …
<ms> I aaprobe sid=- gen=0 ev=summary a_excl_mean_ms=… b_shared_mean_ms=… c_track_mean_ms=… gain_a_excl_ms=… gain_b_shared_ms=…
```

Kontrol listesi:
1. Üç `ev=result` satırının hepsinde `err=0` olmalı. Hata varsa, örneğin `err=-896 stage=open`, satırı olduğu gibi NOTES'a yazın.
2. `a_excl` satırında `sharing` ve `mmap` değerlerine bakın; `dumpsys media.aaudio` içinde etkin bir MMAP akışı görünmeli. **Asıl soru budur.**
3. `gain_*_ms` değerlerini T-097 eşiğiyle (≥ 40 ms) karşılaştırın. `lat_p95_ms` ve `xruns` değerleri de not edilmeli (burst ve buf_final ile birlikte).
4. Ton −40 dBFS'te çalınıyor, neredeyse duyulmamalı. Hoparlörden rahatsız edici bir ses gelmemeli.
5. Ölçüm sırasında uygulamayı arka plana alın (Home tuşu). `ev=run_aborted` satırı gelmeli ve ses hemen kesilmeli. Geri dönünce ölçüm yeniden başlar. "Run again" düğmesi de yeniden çalıştırır.

### Test edilmeyenler

- Cihazda hiçbir şey çalıştırılmadı (adb kullanılmadı).
- HarmonyOS'un EXCLUSIVE/MMAP isteğine nasıl yanıt verdiği bilinmiyor.
- `AAudioStream_isMMapUsed` sembolünün bu cihazda `dlsym` ile bulunup bulunmadığı bilinmiyor.
- AudioTrack zaman damgasının bu cihazda ne kadar güvenilir olduğu bilinmiyor.

### Open questions

1. **check.sh kapsamı:** `scripts/check.sh` gradlew'i olan her `probes/*` dizinini derliyor, bu yüzden sonda **otomatik olarak** check'e girdi. Kart "sonda check'e eklenmez" diyordu.
   - Bu Mac'te NDK kurulu olduğu için check geçiyor. NDK 30.0.16248370 ya da CMake 4.1.2 olmayan bir makinede check kırılabilir.
   - `scripts/check.sh` kartın `files:` listesinde olmadığı için ona dokunmadım. Orkestratör karar versin: dışlamak mı (ör. `probes/aaudio-probe` atlanır), yoksa böyle kalmak mı.
2. Ürün AAudio'ya geçerse NDK ürün derlemesine girer; T-097'deki plana göre bunun için bir karar kaydı gerekir. Sonda bunu yapmıyor.
