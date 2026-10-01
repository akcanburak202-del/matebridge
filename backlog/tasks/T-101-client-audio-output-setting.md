---
id: T-101
title: Tablet — panelde "Ses çıkışı" seçeneği (Düşük gecikme / Uyumlu) ve AAudio gecikme ölçümü düzeltmesi
status: done
phase: 5
owner: android-client-dev
depends_on: [T-100, T-096]
decisions: [0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
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

Not: `cpp/mbaudio.cpp` orkestratör onayıyla `files:`'a eklendi (2026-10-01): AAudio sayaçları JNI'da yoktu.

**1. Ses çıkışı ayarı**
- `Settings.audioOut()/setAudioOut()`: `shared_prefs` anahtarı `audio_out`; değer `auto` ("Düşük gecikme", varsayılan) ya da `track` ("Uyumlu"). Bilinmeyen/eksik → `auto`.
- `AudioOutPref.resolve(extraRaw, stored)` (saf): geçerli `--es audio_out` kalıcı ayarı ezer (kaydedilmez); bilinmeyen değer → uyarı + kalıcı ayar. Sonuç kaynak bilgisiyle (`setting|extra`).
- `SinkPolicy.pref` değiştirilebilir olur: `setPref(p)` zinciri sıfırlar ve arıza sayacıyla gelen AAudio kapatmasını kaldırır; kütüphane arızası (`disableAaudio`) kalıcı kalır. TRACK tercihinde kütüphane yine yüklenmez (açılışta `AAudioNative.available` yalnız TRACK değilse sorulur; sonradan AUTO'ya geçilirse `AAudioSink.open` kendisi kontrol eder).
- `AudioPlayout(…, storedOutPref)` + `setOutPref(p)`: politika güncellenir, akış varsa yazıcıya `rebuildReason="pref"` verilir (hemen yeniden açılır). Bu yeniden kurulum 10 s'de 5 sınırına sayılmaz (hızlı dokunuşlar sesi öldürmesin).
- Log: `ev=audio_out_pref value=auto|aaudio|track source=setting|extra|panel stream=0|1`.
- `MainActivity`: panelde koddan eklenen düğme "Ses çıkışı: Düşük gecikme / Uyumlu" (diğer düğmelerle aynı desen, `res/` değişmez). Dokunuş kaydeder ve uygular; panel seçimi başlatma ezmesini bitirir (T-050 `modeOverride` emsali). Yalnız `audioAllowed` iken görünür.

**2. AAudio OutputClock düzeltmesi**
- JNI `counters(handle, LongArray)`: tek çağrıda `getTimestamp(MONOTONIC)` sonucu/konum/zaman, `getFramesRead`, `getFramesWritten`, `now`. Tahsis, kilit ya da log yok; yalnız yazıcı iş parçacığından çağrılır.
- `AudioSink.counters(out)` (varsayılan false → AudioTrack yolu aynen `timestamp` kullanır). `AAudioSink` bunu uygular.
- `OutputClock.onDeviceCounters(...)` (saf): alan ofseti `off = framesWritten(AAudio) − written(bizim)`. Zaman damgası, `framesRead` ile tutarlıysa (şimdiye taşınan konum `framesRead`'in −20…+100 ms gerisinde) bizim alana çevrilerek kullanılır; değilse ya da yoksa çalma konumu `framesRead`'den (şimdi) türetilir. Böylece gecikme ≈ (yazılan − okunan) + donanım gecikmesi; catch-up (okuyucunun yazıcıyı geçip yazma sayacını ileri itmesi) ofsete yansır.
- Ham değerler her AAudio çıkışında iki kez loglanır (`ev=audio_clock_raw phase=first|1s …`; MbLog'da debug seviyesi yok, `I` kullanılır). Kaynak (`ts|read`) ve ofset de yazılır.
- Testler: `OutputClockTest` (catch-up, tutarsız zaman damgası, damga yok, AudioTrack yolu değişmez), `SinkPolicyTest` (`setPref`), `AudioOutPref.resolve`, `Settings` ses çıkışı (yeni test dosyası `AudioOutSettingTest`).

## Handoff

- **Commit:** `67e29c7` (uygulama), plan `959c09b`. Dal `task/T-101-audio-output-setting`.
- **`./scripts/check.sh`:** ALL OK. `libmbaudio.so` (arm64-v8a) yeni `Java_…_AAudioNative_counters` sembolünü dışa veriyor (10 JNI sembolü). Testler: OutputClockTest 12 (+7), SinkPolicyTest 19 (+5), yeni AudioOutSettingTest 4.
- **Dosyalar:** `cpp/mbaudio.cpp` (orkestratör onayıyla), `audio/AAudioNative.kt`, `audio/AAudioSink.kt`, `audio/AudioSink.kt`, `audio/OutputClock.kt`, `audio/SinkPolicy.kt`, `audio/AudioPlayout.kt`, `session/Settings.kt`, `MainActivity.kt`; testler `OutputClockTest`, `SinkPolicyTest`, `session/AudioOutSettingTest`. `res/` değişmedi (düğme diğerleri gibi koddan ekleniyor).
- **Ses çıkışı ayarı:**
  - Panelde "Ses çıkışı: Düşük gecikme / Uyumlu" düğmesi, "Ses" düğmesinin hemen altında. Yalnız `audioAllowed` iken görünür.
  - `shared_prefs` anahtarı `audio_out`, değer `auto` ya da `track`.
  - `--es audio_out aaudio|track|auto` ayarı ezer ama kaydetmez. Düğme etkin tercihi gösterir: `aaudio` ezmesinde "Düşük gecikme" yazar. Panelde dokunuş kaydeder ve ezmeyi bitirir (T-050 `modeOverride` emsali).
  - Akış varken dokunuş çıkışı hemen yeniden açar (`audio_out … reason=pref`). Bu yeniden kurulum 10 s/5 sınırına sayılmaz. Akış yoksa bir sonraki akışta uygulanır.
  - `SinkPolicy.setPref`: zincir baştan başlar, arıza sayacıyla gelen AAudio kapatması unutulur. Kütüphane arızası (`disableAaudio`, LinkageError) kalıcı kalır.
  - TRACK tercihiyle açılışta native kütüphane yine yüklenmez. Sonradan "Düşük gecikme"ye geçilirse `AAudioSink.open` yükler; yüklenemezse AudioTrack'e düşer.
  - Log: `ev=audio_out_pref value=auto|aaudio|track source=setting|extra|panel stream=0|1`. Açılışta bir kez, her panel değişikliğinde bir kez.
- **AAudio saati:**
  - Yeni JNI `counters(handle, LongArray)`: tek çağrıda `getTimestamp(MONOTONIC)` (başarısızsa 0), `getFramesRead`, `getFramesWritten`, `now`. Tahsis, kilit, log ve yukarı çağrı yok. Yalnız yazıcı iş parçacığından, diğer çağrılarla aynı tutamak ömrü kurallarıyla çağrılır. LinkageError, T-100 L1 yolundan geçer (yazıcı yakalar, AAudio kapanır).
  - `OutputClock.onDeviceCounters`: alan ofseti `offset = AAudio framesWritten − bizim written`. Zaman damgası `framesRead` ile tutarlıysa kullanılır: şimdiye taşınmış konum, `framesRead`'in −20…+100 ms gerisinde olmalı (`source=ts`). Tutarsızsa ya da yoksa `framesRead` "şimdi çalınıyor" sayılır (`source=read`; o durumda donanım gecikmesi eklenmez, birkaç ms eksik çıkar). Sonuç bizim alanımıza kaydırılır; A/V matematiği değişmedi.
  - AudioTrack yolu: `counters` yok (varsayılan false), eskisi gibi `timestamp` + `onTimestamp`. Davranış ve değerler değişmez.
- **Kök neden (cihazda doğrulanacak, bu kartta adb yok):**
  - Eski hesap, bizim yazma sayacımızı (`preFrames` + yazılanlar) AAudio zaman damgasının `framePosition`'ıyla karıştırıyordu.
  - MMAP'te bu iki sayaç aynı alanda değil. AAudio başlangıçta yazma sayacını, çoktan koşan okuyucuya yetiştiriyor (`advanceClientToMatchServerPosition`, catch-up). Zaman damgası konumu da donanım/servis sayacından geliyor (`mFramesOffsetFromService`).
  - ~430 ms sapma, damga konumunun bizim sayacımızdan ~20 600 kare geride olduğunu gösteriyor. İki aday var:
    - (a) Damga alanı `framesWritten/Read` ile aynı; fark bizim sayaçla AAudio sayacı arasında. Logda `offset` ≈ −20 600 ve `source=ts` görülür.
    - (b) Damga, okuma sayacından da farklı bir alanda. Logda `ts_lag_us` ≈ 430 000 ve `source=read` görülür.
  - Düzeltme iki durumda da gecikmeyi `framesWritten − framesRead` (+ donanım) olarak verir. Hangisi olduğu `audio_clock_raw`'dan okunup NOTES'a yazılmalı.
  - Testler: catch-up (±20 640 kare ofset), başka alandaki damga, damga yok, eski damga, ve eski hesabın aynı sentetik akışta 430 ms kaydığı.
- **Ham log:** `ev=audio_clock_raw stream_id phase=first|1s frames_written frames_read ts_pos ts_ns now_ns ts_lag_us our_written pre offset buf source latency_us`. Her AAudio çıkışında iki kez yazılır: ilk okuma (catch-up öncesi olabilir) ve ~1 s sonra. Ses içeriği yok. MbLog'da debug seviyesi olmadığından `I` ile yazılır.
- **Varsayımlar:**
  - Tutarlılık penceresi −20…+100 ms. Donanım sunum gecikmesinin 100 ms'yi aşmadığı varsayıldı; T-099'da toplam çıkış ~13 ms ölçülmüştü.
  - "Düşük gecikme" = `AUTO` (karar 0012 zinciri). `AAUDIO` yalnız ek parametreyle seçilir.
- **Test edilmedi (cihaz gerekiyor):** Hepsi. adb kullanılmadı.
- **Tablette kontrol edilecekler** (`adb logcat -s 'MB:*'`, `MB/audio`):
  1. Varsayılan açılış: `audio_out_pref value=auto source=setting`, sonra `audio_out api=aaudio … mmap=1`. İki `audio_clock_raw` satırı: `offset`, `ts_lag_us` ve `source` NOTES'a yazılmalı (kök neden a ya da b). Stats'ta `audio_ms` ~35–45 ms (+ağ) civarına inmeli. `av_offset_ms` makul olmalı (~−10…+30), 430 değil. `latency_us` ≈ `buf` (480 kare = 10 ms) + birkaç ms.
  2. Panelde "Ses çıkışı" düğmesi "Düşük gecikme" yazıyor. Dokununca "Uyumlu" olmalı ve `audio_out_pref value=track source=panel stream=0|1` görülmeli. Akış varsa hemen `audio_out api=track … reason=pref`; ses kısa bir kesintiyle devam etmeli. `audio_ms` T-098 gibi ~170–190 ms olmalı. Geri dokununca `api=aaudio`.
  3. Uygulamayı kapatıp açınca seçim korunmalı (`source=setting value=track`). `--es audio_out aaudio` ile açılışta `source=extra value=aaudio` görülmeli ve düğme "Düşük gecikme" göstermeli. Sonraki normal açılışta kayıtlı değer yine `track` olmalı.
  4. Hızlı art arda 6+ dokunuş sesi öldürmemeli: `audio_rebuild_limit` görülmemeli, takılı ses olmamalı.
  5. T-100'ün 3–4. maddeleri (kulaklık tak/çıkar, durdur/arka plan/yeniden bağlan) iki ayarda da kısaca tekrar denenmeli.

## Açık sorular

- `docs/LOGGING.md` kapsam dışı. Yeni olaylar `audio_out_pref` ve `audio_clock_raw` gerekirse orkestratör ekleyebilir.
- `audio_clock_raw` her AAudio çıkışında 2 satır. Kök neden kesinleşince ayrı bir kartta kaldırılabilir ya da seyrekleştirilebilir.
- Akış daha önceki yazıcının bitmesini beklerken (`run()` başı) tercih değişirse, çıkış yeni tercihle açılır ve sonra bir kez gereksiz yeniden açılır. Zararsız, ama bilerek bırakıldı.

