---
id: T-095
title: Tablet — ses çalma (AudioTrack düşük gecikme, titreşim tamponu, saat kayması yeniden örnekleme, A/V hizalama)
status: review
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

- [x] **HELLO ve tercih:**
  - HELLO `capabilities` bit8 `AUDIO_PCM` artık gönderilir.
  - ACCEPTED sonrası ve ayar değişince `AUDIO_PREFS`. Ses ayarı varsayılan açık, kalıcı (`shared_prefs`), bağlantı panelinde basit bir "Ses" anahtarı.
  - `--ez audio false` deney düğmesi.
- [x] **`AudioJitterBuffer`** (saf):
  - Önceden ayrılmış ~300 ms `ShortArray` halka ve `(yazılan kare, capture_us)` çapa halkası.
  - `sample_index` boşluğu sessizlikle dolar. Taşma: en eski atılır, kısa sönümle.
  - Yeni `stream_id` ya da `STOPPED`: sıfırla.
- [x] **`DriftController`** (saf):
  - 1–2 s penceredeki tampon seviyesinin tabanını hedefe (~5 ms güvenlik payı) tutar.
  - Alt taşmada hedefe hemen yeniden dolar. Fazlalığı yeniden örnekleme oranıyla yavaşça eritir: normalde ±%0,1, hedefin 20 ms üstündeyken ±%0,5.
  - 120 ms üstünde sert yeniden eşitleme: sön, atla, aç.
- [x] **`CubicResampler`** (saf): 4 noktalı Hermite, oran 1'e çok yakın.
- [x] **`AudioRamp`** (saf): alt taşmada 3 ms sönüş + sessizlik, yeniden başlarken 5 ms açılış. Tıklama yok.
- [x] **`AudioPlayout`** (Android):
  - AudioTrack ömrü ve yazıcı iş parçacığı.
  - `getTimestamp` ile çalma konumu. `ERROR_DEAD_OBJECT` ve yönlendirme değişiminde (`addOnRoutingChangedListener`) izi yeniden kurar.
  - `ACTION_AUDIO_BECOMING_NOISY`'de sessizlik yazar.
  - Ses odağı (focus) istenmez; tabletin kendi medyası çalmaya devam eder.
  - Oturum sonu, arka plan ya da `AUDIO_CONFIG(STOPPED)`: `pause`/`flush`/`release`, halka boşalır.
- [x] **A/V hizalama:**
  - Çalma gecikmesi `capture_us`'den (ClockSync ile) hesaplanır.
  - Ses video sunum gecikmesinden (pacer) **en çok 10 ms erken** olabilir; hedef ≤ 40 ms geç.
  - Video asla sese göre geciktirilmez.
  - Log: `av_offset_ms`.
- [x] **Log** `MB/audio`, saniyede bir, yalnızca çalarken:
  - `perf_mode`, `burst`, `buf_frames`;
  - `level_ms_floor`, `ratio_ppm`, `underruns`, `drops`, `gaps`;
  - `av_offset_ms`.
  - Açılışta bir kez: `AudioManager` yerel hız/burst, `FEATURE_AUDIO_LOW_LATENCY`, verilen `performanceMode`.
  - Ses içeriği asla loglanmaz.
- [x] Girdi ve video yolları değişmez; ses hatası oturumu düşürmez.
- [x] Saf sınıflar JVM birim testli: boşluk doldurma, taşma, kayma, PI denetleyici yakınsaması (sentetik ±200 ppm saat), yeniden örnekleyici (sinüs, düşük bozulma), rampa.
- [x] `./scripts/check.sh` geçiyor. adb kullanılmaz (cihaz testi orkestratörde).

## Plan

**Saf sınıflar** (`client/audio/`, JVM testli):
1. `AudioJitterBuffer`: 300 ms (14400 kare) önceden ayrılmış stereo `ShortArray` halka; mutlak `writePos/readPos` (Long), `(pos, capture_us)` çapa halkası (128). `write(sampleIndex, captureUs, pcm, frames)`: ilk paket başlangıcı belirler; ileri sıçrama → eski kuyruğa 3 ms sönüş + sessizlik + yeni paketin başına 3 ms açılış (`gaps`); sıçrama ≥ kapasite → sıfırla; geri/çakışan kısım atılır. Taşma: en eski kareler çapraz geçişle (crossfade, 3 ms) atılır (`drops`). `peek/consume`, `skipCrossfade(n)` (sert yeniden eşitleme), `captureTimeAt(readPos)`. Senkronize (ağ ve yazıcı iş parçacığı).
2. `CubicResampler`: 4 noktalı Hermite (Catmull-Rom), adım = oran; `process(out, outFrames, step, in, inFrames) → tüketilen`. Girdi biterse sıfır.
3. `AudioRamp`: kazanç rampası; `fadeOut(3 ms)`, `fadeIn(5 ms)`, `apply(buf, frames)`, `isSilent`.
4. `DriftController`: çıkış karesiyle ölçülen 1 s pencerede "okuma sonrası kalan" seviyenin tabanı/tepe aralığı. PI (Kp 200 ppm/ms, Ki 10 ppm/(ms·s), integral ±1000 ppm), sınır ±1000 ppm, |hata| > 20 ms iken ±5000 ppm. Taban > hedef + 120 ms → `Resync(drop)`. Hedef − taban > 30 ms → `Rebuffer`. Hedef = max(güvenlik, A/V tabanı). Güvenlik 5 ms; alt taşmada +5 ms (en çok 40 ms), 10 temiz pencerede −1 ms. Yeniden dolum eşiği = hedef + son pencere aralığı (en az 1 paket). A/V: `onAvOffset(avUs)` → istenen taban = son taban + (+5 ms − av), 5 ms ölü bölge, [0, 200 ms].
5. `PlayoutCore`: tampon + kontrolcü + yeniden örnekleyici + rampa; durumlar PRIMING (sessizlik, tüketmez) → PLAYING → FADING_OUT (alt taşma öngörüsü: burst sonrası < 3 ms kalırsa) → PRIMING. `render(out, frames)`, sessize alma (noisy). Bütün burst mantığı burada, böylece ±200 ppm simülasyonu uçtan uca test edilir.

**Android** (`AudioPlayout`): akış başına yazıcı iş parçacığı (`THREAD_PRIORITY_URGENT_AUDIO`), AudioTrack 48 kHz s16 stereo `PERFORMANCE_MODE_LOW_LATENCY` (`USAGE_MEDIA`, FAST verilmezse `USAGE_GAME`), `setBufferSizeInFrames(2×burst)`, `underrunCount` artınca +1 burst (≤ 6). `play()` hemen; PRIMING sessizlik yazar. `ERROR_DEAD_OBJECT` / yönlendirme cihazı değişince iz yeniden kurulur (10 s'de en çok 5). `getTimestamp` (250 ms'de bir) ile okuma başının çalma zamanı → `audio_ms`; `av_offset = audio_ms − video_ms`. Ses odağı istenmez. `ACTION_AUDIO_BECOMING_NOISY` → yeni akışa kadar sessiz. STOPPED / oturum sonu / onStop / ayar kapalı → yazıcı durur: `pause/flush/release`. Log `MB/audio`: açılış (yerel hız/burst, `FEATURE_AUDIO_LOW_LATENCY`, verilen mod) ve çalarken saniyede bir. Tüm hatalar yakalanır; oturuma dokunmaz.

**Oturum:** `SessionMachine` `initialAudio: Boolean?` (null = hiç gönderme) + `Event.SetAudio`; ACCEPTED'da DISPLAY_RATE'ten sonra `AUDIO_PREFS`, değişince yeniden. `SessionController`: `setAudioEnabled`, AUDIO_CONFIG/FRAME okuyucu iş parçacığından doğrudan dinleyiciye (`onAudio`, motor kuyruğunu atlar, yalnız güncel bağlantı). `Settings.audioEnabled()` (varsayılan açık).

**MainActivity:** HELLO bit8 (`--ez audio false` → bit yok, AUDIO_PREFS yok, çalma yok), panelde "Ses: açık/kapalı" düğmesi, statsTick'te `video_ms = latency_avg + pace_add + 1 vsync` → `AudioPlayout`, Connected dışı durumda ve onStop'ta ses durur.

**Testler:** tampon (boşluk, taşma, çakışma, çapa), yeniden örnekleyici (1 kHz sinüs, oran 1,001, düşük hata; oran 1 = gecikmeli kopya), rampa, sürüklenme simülasyonu (±200 ppm + titreşim; yakınsama, alt taşma yok), sert eşitleme, A/V tabanı, SessionMachine AUDIO_PREFS sırası.

## Handoff

**Commit:** `19961f5` (plan: `30aa794`), branch `task/T-095-client-audio` (T-093'ün `task/T-093-audio-codecs` dalı üstünde).

**Dosyalar:**
- Yeni `client/audio/`: `AudioJitterBuffer`, `CubicResampler`, `AudioRamp`, `DriftController`, `PlayoutCore` (saf burst mantığı), `AudioStreamGate` (akış/biçim kuralları), `AvSync` (zaman aritmetiği), `AudioPlayout` (Android: AudioTrack + yazıcı iş parçacığı).
- `session/SessionMachine.kt` (`initialAudio`, `Event.SetAudio`, ACCEPTED'da DISPLAY_RATE'ten sonra AUDIO_PREFS), `session/SessionController.kt` (`setAudioEnabled`, `onAudio`: AUDIO_CONFIG/FRAME okuyucudan doğrudan, yalnız güncel bağlantı; `onSessionEnd` CloseControl'de), `session/Settings.kt` (`audio_enabled`, varsayılan açık), `MainActivity.kt` (HELLO bit8, "Ses" düğmesi, `--ez audio false`, video gecikmesi → A/V, onStop/oturum sonu/yeni bağlantıda durdurma).
- Testler: `test/.../audio/` (5 dosya, 32 test) + `test/.../session/AudioPrefsMachineTest.kt` (5 test).

**`./scripts/check.sh`: ALL OK.**

**Varsayımlar / kararlar:**
- Seviye = burst okunduktan sonra tamponda kalan. Alt taşma öngörüsü: bir burst sonrası < 3 ms kalacaksa 3 ms sönüş, sonra PRIMING; yeniden başlama eşiği = hedef + son pencere aralığı (≥ 1 paket), 5 ms açılış.
- Güvenlik payı uyarlamalı: 5 ms başlar, her alt taşmada +5 ms (≤ 40 ms), 10 temiz saniyede −1 ms.
- PI: Kp 100 ppm/ms, Ki 5 ppm/(ms·s) (200/10 ile simülasyonda paket testere dişi yüzünden sınır döngüsü oluştu). ±200 ppm simülasyonda ortalama oran ±20 ppm içinde, salınım < 300 ppm (duyulmaz).
- Taşma ve sert yeniden eşitleme (taban > hedef + 120 ms) tampon içinde 3 ms **çapraz geçişle** atlar (sön + atla + aç tek adımda). Hedef − taban > 30 ms (A/V hedefi çok yükseldi) → sönüş + yeniden dolum (alt taşma sayılmaz).
- `sample_index` sıçraması en çok 100 ms sessizlikle doldurulur (host zaten en çok 100 ms tutar); daha büyük sıçrama zaman ekseni kayması sayılır, çapalar capture zamanını doğru tutar.
- A/V: `audio_ms` = getTimestamp ile bir sonraki yazılan karenin duyulma anı − okuma başının capture zamanı (ClockSync). `video_ms` = STATS gecikmesi (yakalama→decoder çıkışı) + pacer ekleme + 1 vsync (kompozisyon tahmini, ölçülmüyor). Hedef: ses +5 ms geç, 5 ms ölü bölge; yalnız ses tamponu büyütülür/küçültülür, video asla.
- Noisy: akış yeni `stream_id` ile yeniden başlayana kadar sessiz (Ses düğmesi kapat/aç ya da yeniden bağlantı).
- `--ez audio false`: HELLO bit8 yok, AUDIO_PREFS yok, AudioPlayout oluşturulmaz, Ses düğmesi gösterilmez.

**Test edilmedi (tablet gerekli):** AudioTrack FAST yolu, gerçek burst/gecikme, yönlendirme/dead-object yeniden kurma, noisy, A/V hizası, HarmonyOS davranışı. Host tarafı (T-094) olmadan uçtan uca çalınamaz.

**Tablette kontrol (orkestratör):**
1. Açılış logu: `adb logcat -s MB/audio` → `ev=audio_device native_rate=48000 native_burst=… low_latency_feature=…`; akış başlayınca `ev=audio_track perf_mode=low_latency usage=media` (değilse `usage=game` denendi mi; `perf_mode=none` ise FAST yok → not al).
2. Mac'te müzik/video çal: ses tablette kesintisiz mi; `ev=stats` satırında `underruns` ve `track_underruns` sabit kalıyor mu, `level_ms_floor` ≈ `target_ms`, `ratio_ppm` küçük (|·| < 200).
3. Dudak senkronu: video izle, `av_offset_ms` −10…+40 aralığında mı; gözle/klaket testiyle doğrula (`video_ms` tahmini 1 vsync varsayıyor).
4. Bağlantı panelindeki "Ses" düğmesi: kapat → tablet hemen susar, Mac sesi geri gelmeli (host); aç → yeni `audio_start stream_id=N+1`. Uygulama arka plana → `audio_stop reason=background`, Mac sesi geri gelir.
5. Kulaklık tak/çıkar (veya BT): `audio_rebuild`/`audio_track reason=routing`, çıkarınca `audio_noisy muted=1` ve hoparlörden ses gelmemeli. Kalem/klavye/video etkilenmemeli; `--ez audio false` ile HELLO'da bit8 olmamalı.

## Open questions

- `protocol/Messages.kt` içindeki `Capabilities.AUDIO_PCM` yorumu hâlâ "Not sent until playback exists (T-095)" diyor; dosya bu kartın listesinde değil, dokunmadım (orkestratör güncelleyebilir).
- `video_ms` tahmini ekran hattını 1 vsync sayıyor; cihazda klaket testiyle doğrulanmalı, gerekirse sabit ayarlanır.
