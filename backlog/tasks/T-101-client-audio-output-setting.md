---
id: T-101
title: Tablet — panelde "Ses çıkışı" seçeneği (Düşük gecikme / Uyumlu) ve AAudio gecikme ölçümü düzeltmesi
status: in-progress
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

