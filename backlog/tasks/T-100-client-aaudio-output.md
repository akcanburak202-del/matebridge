---
id: T-100
title: Tablet — ses çıkışı AAudio MMAP (NDK/C++), AudioTrack'e otomatik geri dönüş
status: in-progress
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

**Veri yolu seçimi: kendi yazıcı iş parçacığı + sınırlı süreli `AAudioStream_write` (geri çağrı yok).**
- Gerekçe: bugünkü yazıcı (THREAD_PRIORITY_URGENT_AUDIO, burst başına bir yazma, cihaz saatinde ilerler) ve `PlayoutCore` aynen kalır; A/V ve `audio_ms` hesabı "yazılan kare + zaman damgası" ile her iki çıkışta aynıdır. Geri çağrı seçilseydi araya kilitsiz bir halka girerdi: halkanın doluluğu ek gecikme ve ayrı bir hız denetimi (yazıcının ne zaman uyuyacağı) gerektirirdi, A/V hesabı da halka seviyesini katmak zorunda kalırdı.
- `write` zaman aşımlı çağrılır (≤ 100 ms). AAudio içeride tam olarak "bloklamayan yazma + saat modeline göre uyuma" döngüsünü yapar (MMAP'te futex/uyku, kilit yok); yani karar 0012/3'teki "bloklamayan write ile kendi iş parçacığı" seçeneğinin AAudio'ya bırakılmış hız denetimi. Zaman aşımı, durdurmanın en çok bir zaman aşımı kadar beklemesini garanti eder (normalde ≤ 1 burst = 5 ms).
- C++ veri yolunda tahsis ve kilit yok: PCM `GetShortArrayRegion` ile açılışta ayrılan yerel tampona kopyalanır (kritik bölge tutulmaz), sonra `AAudioStream_write`. Zaman damgası `SetLongArrayRegion` ile önceden ayrılmış `LongArray`'e yazılır. Log ve JNI yukarı çağrısı yok.
- Akış yalnızca yazıcı iş parçacığına aittir: aç/başlat/yaz/durdur/kapat hep oradan. Başka iş parçacığından `stop` yalnızca bayrak indirir (AAudio'da eşzamanlı `requestStop`/`close` riski yok); AudioTrack'te bugünkü pause+flush kesmesi korunur.

**Kod**
- `cpp/CMakeLists.txt`, `cpp/mbaudio.cpp`: `libmbaudio.so`. JNI: `open(sharing, startBursts, info)` → tutamak (bilgi: hata, paylaşım, mmap, burst, kapasite, tampon, hız, kanal, biçim, perf), `start`, `write`, `timestamp(CLOCK_MONOTONIC)`, `xruns`, `bufferSize`/`setBufferSize`, `stopAndClose`. `isMMapUsed` `dlsym` ile bir kez çözülür (başlıkta yok; -1 = bilinmiyor). Açılışta bir burst sessizlik başlatmadan önce yazılır (sondadaki gibi).
- `AudioSink` (arayüz): `api`, `burst`, `bufFrames`, `preFrames`, `write`, `timestamp(LongArray)`, `xruns`, `grow`, `interrupt`, `close` (tek seferlik), log alanları. `TrackSink` (bugünkü `Track` + açma kodu, yönlendirme dinleyicisi) ve `AAudioSink` (`AAudioNative` JNI nesnesi; kütüphane yüklenemezse `available=false`).
- `AudioPlayout.Stream` yazıcısı çıkıştan bağımsız olur: burst = çıkışın burst'ü, yeniden kurulum, xrun ile tampon büyütme (birinci saniye sayılmaz), stats.
- Saf Kotlin (JVM testli):
  - `AudioOutPref.parse("aaudio"|"track"|null)` (`--es audio_out`; bilinmeyen değer → auto + uyarı).
  - `SinkPolicy`: karar 0012/2 sırası. auto: EXCLUSIVE → (EXCLUSIVE istendi ama paylaşım/MMAP farklı, ya da açılamadı → SHARED, gecikme sınavıyla) → AudioTrack. `aaudio`: AAudio sınavsız (yine de açılamazsa AudioTrack). `track`: yalnızca AudioTrack. Yeni akışta ve cihaz değişiminde (DISCONNECTED/yönlendirme) zincir baştan denenir. AAudio arızaları (DISCONNECTED, yazma hatası, takılma) 10 s içinde 3 kez → AAudio bu `AudioPlayout` ömrü boyunca kapatılır, AudioTrack'e düşülür; oturum etkilenmez.
  - `SharedLatencyProbe`: SHARED akışta ilk 300 ms ısınmadan sonra ~500 ms boyunca her burst `presentTime(written) − now` ölçer; medyan > 60 ms (AudioTrack 99 ms − T-097'nin 40 ms kazanç eşiği) ya da zaman damgalarının çoğu başarısızsa → red, AudioTrack'e geçilir. 2 s içinde karar çıkmazsa red.
  - `OutputLatency`: aynı formül (`AvSync.presentTimeUs` − şimdi) iki çıkış için.
  - `AudioBufferConfig.startBursts(raw, default)`: `--ei audio_buf_bursts` her iki çıkışa uygulanır; varsayılan AudioTrack 1, AAudio 2 (sondada 0 xrun).
- Log: açılış ve yeniden kurulumda `ev=audio_out api=aaudio|track sharing=exclusive|shared|- mmap=1|0|-1|- burst= buf= capacity= reason= stream_id= …`; `audio_out_failed`, `audio_out_fallback`, `audio_shared_probe`. Stats: `api=` ve `xruns=` (`track_underruns=` bunun yerine geçer).
- `build.gradle.kts`: `ndkVersion = "30.0.16248370"`, CMake 4.1.2, `abiFilters arm64-v8a`, `-Wall -Werror`. `README.md` ve `client-android/AGENTS.md`'ye NDK/CMake notu.
- Yaşam döngüsü kuralları (gate, tek seferlik kapatma, önceki akışı bekleme) değişmez; `session/` ve `MainActivity`'ye dokunulmaz.

## Handoff

