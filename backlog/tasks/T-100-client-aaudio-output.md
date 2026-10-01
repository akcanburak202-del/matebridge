---
id: T-100
title: Tablet — ses çıkışı AAudio MMAP (NDK/C++), AudioTrack'e otomatik geri dönüş
status: review
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

- [x] `cpp/` altında küçük bir AAudio sarmalayıcı (JNI):
  - aç: 48 kHz, s16 stereo, `LOW_LATENCY`, istenen paylaşım;
  - başlat, durdur, kapat;
  - `framesPerBurst`, `bufferSize`;
  - `getTimestamp(CLOCK_MONOTONIC)`;
  - xrun sayısı;
  - verilen paylaşım ve MMAP durumu.
  - Veri yolu, karar 0012 madde 3'e uygun (tahsis ve kilit yok). Seçilen yöntem Plan'da gerekçelendirilir.
- [x] `AudioPlayout`'a çıkış soyutlaması (`AudioSink`: AudioTrack | AAudio).
  - Mevcut `PlayoutCore` (titreşim tamponu, kayma, rampa, A/V) değişmeden iki çıkışla çalışır.
  - Çalma konumu ve gecikme her iki çıkıştan aynı biçimde alınır; A/V hesabı ve `audio_ms` doğru kalır.
- [x] Seçim sırası karar 0012 madde 2'deki gibi. `--es audio_out aaudio|track` anahtarı.
- [x] Log, açılışta ve yeniden kurulumda: `ev=audio_out api=aaudio|track sharing=… mmap=… burst=… buf=…`. Stats satırında `api=` ve `xruns=`.
- [x] `AAUDIO_ERROR_DISCONNECTED` ve yönlendirme değişiminde akış yeniden açılır. Üst üste başarısızlıkta AudioTrack'e düşülür ve oturum etkilenmez.
- [x] Yaşam döngüsü (durdur/arka plan/oturum sonu/yeni `stream_id`) T-095/T-098 kurallarıyla aynı; tek seferlik kapatma.
- [x] `build.gradle.kts`: `ndkVersion = "30.0.16248370"`, `externalNativeBuild` CMake 4.1.2, yalnızca `arm64-v8a` (tablet). `client-android/AGENTS.md` ve `README.md`'ye NDK ve CMake gereksinimi notu.
- [x] Saf Kotlin parçaları (seçim ve geri dönüş karar makinesi, konum ve gecikme hesabı) JVM testli. C++ kısmı derleniyor.
- [x] `./scripts/check.sh` geçiyor. adb kullanılmaz (cihaz testi orkestratörde).

## Plan

**Veri yolu seçimi: kendi yazıcı iş parçacığı + sınırlı süreli `AAudioStream_write` (geri çağrı yok).**
- Gerekçe: bugünkü yazıcı (THREAD_PRIORITY_URGENT_AUDIO, burst başına bir yazma, cihaz saatinde ilerler) ve `PlayoutCore` aynen kalır; A/V ve `audio_ms` hesabı "yazılan kare + zaman damgası" ile her iki çıkışta aynıdır. Geri çağrı seçilseydi araya kilitsiz bir halka girerdi: halkanın doluluğu ek gecikme ve ayrı bir hız denetimi (yazıcının ne zaman uyuyacağı) gerektirirdi, A/V hesabı da halka seviyesini katmak zorunda kalırdı.
- `write` zaman aşımlı çağrılır (200 ms). AAudio içeride tam olarak "bloklamayan yazma + saat modeline göre uyuma" döngüsünü yapar (MMAP'te futex/uyku, kilit yok); yani karar 0012/3'teki "bloklamayan write ile kendi iş parçacığı" seçeneğinin AAudio'ya bırakılmış hız denetimi. Zaman aşımı, durdurmanın en çok bir zaman aşımı kadar beklemesini garanti eder (normalde ≤ 1 burst = 5 ms).
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

- **Commit:** `2f080e5` (uygulama), `5ea29e4` (inceleme düzeltmeleri M1/L1/L2), plan `255e3a3`. Dal `task/T-100-aaudio-output`.
- **`./scripts/check.sh`:** ALL OK (client-android: `assembleDebug` + `libmbaudio.so` arm64-v8a APK içinde, 9 JNI sembolü Kotlin `external` adlarıyla eşleşiyor; yeni testler SinkPolicyTest 14 (inceleme sonrası; MMAP olmayan red ve `disableAaudio` dahil), SharedLatencyProbeTest 9, OutputClockTest 5, AudioBufferConfigTest +1).
- **Dosyalar:**
  - yeni: `cpp/CMakeLists.txt`, `cpp/mbaudio.cpp`, `audio/AAudioNative.kt`, `audio/AudioSink.kt`, `audio/AAudioSink.kt`, `audio/TrackSink.kt`, `audio/SinkPolicy.kt` (+`AudioOutPref`, `OutChoice`), `audio/SharedLatencyProbe.kt`, `audio/OutputClock.kt`, testler `SinkPolicyTest`, `SharedLatencyProbeTest`, `OutputClockTest`;
  - değişen: `audio/AudioPlayout.kt` (yazıcı çıkıştan bağımsız; eski `Track` sınıfı `TrackSink`'e taşındı, davranışı aynı), `audio/AudioBufferConfig.kt` (AAudio varsayılanı 2 burst), `AudioBufferConfigTest.kt`, `app/build.gradle.kts`, `client-android/AGENTS.md`, `README.md`.
  - `session/`, `MainActivity`, `PlayoutCore` ve diğer ses sınıflarına dokunulmadı.
- **Varsayımlar:**
  - **İnceleme düzeltmeleri (5ea29e4):**
    - M1: MMAP olmayan ya da MMAP durumu bilinmeyen (`mmap != 1`) AAudio akışı her tercihte reddedilir, `--es audio_out aaudio` dahil. Akış kapatılır (`ev=audio_out_rejected reason=not_mmap`), sonra AudioTrack açılır. Gerekçe: legacy akışın `write`'ı zaman aşımına uymaz, durdurma takılabilir. Bu yüzden SHARED sınavı artık yalnızca shared + MMAP akışa uygulanır.
    - L1: `AAudioSink.open` içindeki `LinkageError` → `SinkOpenException(aaudioUnusable)` → `SinkPolicy.disableAaudio()` → AudioTrack. Yazıcıda `LinkageError` yakalanır (süreç ölmez) ve AAudio kapatılır; `finally` içindeki kapatma da yakalar.
    - L2: Akış açıldıktan sonraki ilk 0,5 s'de `write` zaman aşımı 1 s, sonra 200 ms. Başlangıçtaki yavaş açılış "stall" sayılmaz.
  - Veri yolu: geri çağrı değil, yazıcı iş parçacığı + `AAudioStream_write` (zaman aşımı 200 ms). Gerekçe Plan'da. Karar 0012/3'teki "bloklamayan write" ifadesini, hız denetimini AAudio'nun kendi bekleme döngüsüne bırakan sınırlı süreli yazma olarak yorumladım (bkz. açık sorular).
  - AAudio akışına başka iş parçacığından hiç dokunulmaz; `stop` yalnızca bayrak indirir, yazıcı ≤ 1 burst içinde çıkar ve akışı kapatır. 200 ms içinde tüketmeyen akış "stall" sayılır ve yeniden açılır.
  - Yönlendirme değişimi AAudio'da `DISCONNECTED` olarak gelir (MMAP ve Android 9+ legacy). Ayrı bir yönlendirme dinleyicisi yok. AudioTrack'teki dinleyici aynen korunuyor.
  - SHARED sınavı: 300 ms ısınma + 500 ms ölçüm, medyan ≤ 60 ms kabul; zaman damgaları çoğunlukla başarısızsa ya da 2 s'de karar yoksa red. T-099'da SHARED 494 ms ve tutarsız ölçüldü, bu cihazda reddedilmesi beklenir.
  - Zincir her yeni `stream_id`'de ve her cihaz değişiminde baştan denenir. AAudio arızası (disconnect/stall/yazma hatası) 10 s'de 3 kez → bu `AudioPlayout` ömrü boyunca AudioTrack. Genel yeniden kurulum sınırı (10 s'de 5) aynı.
  - `--ei audio_buf_bursts N` artık iki çıkışa da uygulanır. Yoksa AudioTrack 1, AAudio 2 burst. Büyüme en çok 6 burst (AAudio'da kapasiteyle sınırlı).
  - **Log değişiklikleri (grep'ler güncellenmeli):**
    - `ev=audio_track` → `ev=audio_out` (alanlar: `api sharing mmap burst buf capacity perf_mode [usage] stream_id reason requested probation pref native_rate rate`). `buf_frames=` artık `buf=`, `buf_bursts=` ise `audio_device` satırında.
    - `ev=audio_track_failed` → `ev=audio_out_failed` (`requested=exclusive|shared|track` + neden).
    - `ev=audio_buffer_grow`: `track_underruns=` → `xruns=`, yeni `api=`. Artık yalnızca tampon gerçekten büyüdüğünde loglanır; eskiden xrun artışında büyüme başarısız olsa da yazılıyordu.
    - `ev=stats`: `track_underruns=` → `xruns=`, yeni `api=`.
    - `ev=audio_rebuild_limit` ve `ev=audio_write_failed`: yeni `api=` alanı.
    - `ev=audio_device`: yeni `audio_out=` ve `aaudio_lib=` alanları; `buf_bursts=` verilmemişse `default`.
    - Yeni olaylar: `audio_out_rejected`, `audio_out_fallback`, `audio_shared_probe`, `audio_out_pref_unknown`.
- **Test edilmedi (cihaz gerekiyor):** AAudio yolunun hiçbiri cihazda çalıştırılmadı (adb kullanılmadı).
- **Tablette kontrol edilecekler** (`adb logcat -s 'MB:*'` → `MB/audio`):
  1. Varsayılan açılış: `ev=audio_out api=aaudio sharing=exclusive mmap=1 burst=240 buf=480 … probation=0`. Ses çalıyor, cızırtı ve tıkırtı yok. Stats'ta `api=aaudio`, `xruns=0` (ya da büyüme sonrası sabit). `audio_ms` T-098'e göre ~85 ms düşük (~90–100 ms), `av_offset_ms` makul.
  2. `--es audio_out track`: `api=track`, davranış T-098 ile aynı (`audio_ms` ~170–190). `--es audio_out aaudio`: exclusive yine seçilmeli.
  3. Oturum sürerken kulaklık tak/çıkar (ya da BT): `audio_out … reason=disconnected` ve ses devam ediyor. BT'de büyük olasılıkla `audio_out_failed`/`audio_out_rejected reason=not_mmap` → `api=track`. Oturum düşmemeli.
  4. Durdur/arka plana al/oturumu bitir/yeniden bağlan (yeni `stream_id`): her seferinde tek `audio_stop`, sonra yeni `audio_out`. Takılı kalan ses, çökme ya da "audio_previous_slow" olmamalı.
  5. EXCLUSIVE açıkken tablette başka bir uygulamanın sesi (ör. video) hâlâ duyuluyor mu? (karar 0012 sonuçlar). Ayrıca video kod çözme yükü altında `xruns` artıyor mu? Artıyorsa `audio_buffer_grow` görülmeli.

## Açık sorular

- ~~Karar 0012/3 ve zaman aşımlı `write`~~: orkestratör kabul etti (MMAP'te zaman aşımlı bloklayan yazma); karar metnini o güncelleyecek.
- Yazıcı iş parçacığı SCHED_FIFO değil (THREAD_PRIORITY_URGENT_AUDIO). Cihazda xrun görülürse veri geri çağrısı + kilitsiz halka seçeneği (karar 0012/3'ün diğer kolu) yeni bir kart olabilir.
- `docs/LOGGING.md` bu kartın `files:` listesinde değil. `ev=audio_out`, `audio_out_failed`, `audio_out_fallback`, `audio_shared_probe` olayları ve stats'taki `api=`/`xruns=` (eski `track_underruns=`) gerekiyorsa orkestratör ekleyebilir.

