---
id: T-287
title: İstemci — uzun sessizlikte AAudio akışını duraklat (ses yokken 200 uyanma/s, %2)
status: review
phase: 6
owner: android-client-dev
depends_on: [T-282]
decisions: [0011]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/cpp/mbaudio.cpp
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/DevKnobs.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/DevKnobsTest.kt
  - backlog/tasks/T-287-audio-idle-pause.md
---

## Amaç

T-282 ölçümü (`docs/research/2026-10-07-perf-profile.md` §Sıcak noktalar 4): ses yokken `mb-audio` 200 uyanma/s ve %2,2 tek çekirdek; AAudio MMAP her 5 ms'de sessizlik yazıyor. Host T-279'dan beri 500 ms sessizlikten sonra paket göndermiyor. Günün çoğunda ses yok. Protokol değişmez.

## Kabul

1. İstemci `state=idle` (paket gelmiyor) **en az 10 sn** sürünce çıkış akışını duraklatır (`requestPause` ya da `requestStop`; hangisinin Huawei MMAP'ta temiz olduğunu dene, yaz). `mb-audio` döngüsü duraklamada bloklanır, dönmez.
2. İlk ses paketi gelince akış yeniden başlar. İlk paketin çalınma gecikmesi ölçülür ve loglanır (`ev=resume start_ms=…`). Hedef: duraklamasız ilk sese göre ≤ +50 ms. Rampa (`AudioRamp`) tıkırtıyı önler.
3. Duraklama ve devam döngüsü alt taşma ya da `idle_gaps` sayaçlarını yanlış artırmaz. Oturum kapanışı, arka plana geçiş ve `stream_id` değişimi duraklamış akışta da doğru çalışır.
4. Gerçek zamanlı geri çağırmada ayırma, kilit, log yok.
5. Cihaz (orkestratör, kullanıcı 1 dk): sessizken `mb-audio` uyanma ≤ 10/s. Kullanıcı sesli video başlatır, ilk ses gecikmesi logdan okunur. Kullanıcı "ilk ses kesik/geç" demezse kabul.

## Plan

1. **Ne zaman:** `PlayoutCore` PRIMING'de ve `framesSinceLastPacket >= 10 sn` (çıkış karesiyle sayılır; cihaz saatiyle gerçek zamanlı). Yeni saf sınıf `IdlePause` karar verir; yalnızca AAudio (`AudioSink.canPause`), AudioTrack hiç duraklamaz. Duraklatma/devam sonrası ilk render'a kadar yeniden duraklatma yok (çekirdek yeni paketi henüz görmedi).
2. **Duraklatma:** yazıcı iş parçacığı `AAudioNative.pause` (requestPause ya da requestStop + durum bekleme, en çok 200 ms) çağırır, sonra `LockSupport.parkNanos` ile bloklanır. Kontrol okuyucusu her kabul edilen pakette `onPacket()` ile `unpark` eder (yalnızca park durumundayken); `stop()` ve `requestRebuild()` de uyandırır. 1 sn'lik zaman aşımı yalnızca emniyet ağı (1 uyanma/sn).
3. **Devam:** ilk pakette hemen `requestStart` (öncelemeyi beklemeden: başlatma süresi, çekirdeğin seviye bekleme süresiyle örtüşür). Sonra `nextTsAt=0`, `meter.reset()`, `xrunBase=null` (devamdaki ilk saniyenin xrun'ı büyütmeye yol açmaz). `AAudioSink.resume` ilk yazma süresi payını (START_GRACE) yeniler.
4. **requestPause ile requestStop:** varsayılan **requestPause**: arabellek korunur ve AAudio sayaçları (`framesWritten/Read`) süreklidir (OutputClock/HeadroomEstimator alan farkı bozulmaz; bayat zaman damgası gecikme denetimiyle zaten reddedilir); requestStop çıkışta kalan veriyi boşaltıp durur, durum STOPPED olur. AOSP'de ikisi de hizmette aynı yoldan HAL akışını durdurur; Oboe/AAudio rehberlerinde "askıya al = pause, bitir = stop". Cihazda hangisi temiz diye A/B için geliştirici anahtarı `--es audio_idle_pause off|pause|stop` (varsayılan `pause`). Pause/stop ya da start hata verirse bu akış için duraklatma kapanır (devam hatası çıkışı yeniden kurar).
5. **Ölçüm:** `ev=idle_pause`, `ev=resume start_ms=…`, `ev=first_sound ms=…` (ilk paketten ilk duyulur yazmaya; duraklamasız da loglanır, A/B karşılaştırılabilir).
6. **Testler:** `IdlePauseTest` (kurallar, anahtar çözümleme, `FirstSoundTimer`), `IdlePauseSimulationTest` (host sessizlik kapısı + `PlayoutCore` + `IdlePause`: alt taşma yok, `idleGaps` doğru, ilk ses duraklamasız ilk sese göre ≤ başlatma süresi, fade-in sıfıra yakın başlar).

## Handoff

- Commit: kod `360f9f77` (+ bu kartın Handoff commit'i). Dal `task/T-287-audio-idle-pause`. `./scripts/check.sh`: ALL OK (2203 test).
- Dokunulan dosyalar: `cpp/mbaudio.cpp` (yeni `pause` JNI), `audio/AAudioNative.kt`, `AAudioSink.kt`, `AudioSink.kt` (`canPause/pause/resume`, AudioTrack varsayılanları: duraklamaz), `AudioPlayout.kt` (park döngüsü, loglar), yeni `audio/IdlePause.kt` (`IdlePause`, `FirstSoundTimer`), testler `IdlePauseTest.kt`, `IdlePauseSimulationTest.kt`. `CubicResampler.kt` ve `PlayoutCore.kt` dokunulmadı.
- Varsayımlar:
  - AAudio MMAP'ta requestPause/requestStart çalışır (HarmonyOS'ta doğrulanmadı). Çalışmazsa: pause hatası `idle_pause_failed` ile akışta duraklatmayı kapatır; devam hatası `resume` `ok=0` + `audio_rebuild` ile çıkışı yeniden kurar.
  - Duraklatılmış akışa `close` güvenli (native `destroy` requestStop + close).
  - Devamda ilk saniyenin xrun'ı ve ölçerler yok sayılır; bayat zaman damgası `OutputClock`/`HeadroomEstimator` gecikme denetimiyle reddedilir (sayaç kaynağına düşer).
  - 10 sn çıkış karesiyle sayılır (cihaz saatinde gerçek zamanlı). Akış hiç ses almadan 10 sn sessiz kalırsa da duraklar.
- Gerçek zamanlı yol: yazma döngüsüne ayırma/kilit/log eklenmedi; yalnızca `render` öncesi bir `shouldPause` (alan karşılaştırması) ve render sonrası `onRendered`. Okuyucu iş parçacığı pakette `System.nanoTime()` + volatile okuma yapar.
- Test edilmeyen (cihaz gerekir): gerçek AAudio pause/start davranışı ve süreleri, tıkırtı, Huawei MMAP'ta STATE_PAUSED'a ulaşma, uyanma sayısı.

### Cihazda ne bakılacak (orkestratör)

Logcat: `adb logcat -s 'MB/audio'` (ses içeriği loglanmaz).
1. Ses yokken ~10 sn bekle: `ev=idle_pause mode=pause idle_s=10 state=paused pause_ms=<küçük> count=1` satırı. `state` `pausing` ise (zaman aşımı) yaz. Sonra `ev=stats` satırları **kesilir** (yazıcı park halinde). `ev=idle_pause_failed` çıkarsa `code=` ve `state=` yaz, anahtarı `stop` ile dene.
2. Park halindeyken `mb-audio-<id>` iş parçacığı uyanma ≤ 10/s (kabul 5): `adb shell top -H -b -n 1`/`simpleperf` ya da `/proc/<pid>/task/<tid>/status` `voluntary_ctxt_switches` farkı (T-282 yöntemi). Önceki ölçüm: 200/s.
3. Ses başlat: `ev=resume ok=1 paused_ms=… wake_ms=… start_ms=…` (start_ms = requestStart çağrısı; wake_ms = ilk paket → yazıcı uyanışı, <2 ms olmalı) ve `ev=first_sound ms=… idle_pause=pause pauses=1`. İlk ses ardından `ev=stats` yeniden başlar; yeni `underruns`, `xruns`, `idle_gaps` farkı: `idle_gaps` +1 olmalı (zaten sessizlikte de +1), `underruns` artmamalı, `audio_buffer_grow` **olmamalı**, `audio_rebuild_limit`/`audio_out` (yeniden kurma) olmamalı.
4. A/B: aynı sessizlik süresinden sonra `--es audio_idle_pause off` ile `first_sound ms=` oku. Hedef: duraklamalı − duraklamasız ≤ 50 ms. Kayıt örneği en az 3 devam. Kullanıcı sesli video başlatınca ilk ses kesik/geç mi (kabul ölçütü).
5. Dene: `--es audio_idle_pause stop` ile aynı; `pause` mı `stop` mu temiz karar için `idle_pause state=` (paused/stopped), `start_ms` ve ilk sesin tıkırtısı (kullanıcı kulağı).
6. Park halindeyken: Mac sesi kapat/ses uygulamasını aç-kapat, arka plana geç/ön plana dön, oturumu kapat (`audio_stop reason=…` sonrası iş parçacığı çıkmalı, `previous_slow` uyarısı yok), panelden "Ses çıkışı" değiştir (park uyanmalı, `resume_skipped reason=pref`).

## Open questions

1. **Anahtar kablolaması (orkestratör onayıyla dal üzerinde yapıldı, `files:` genişletildi):** `AudioPlayout` yeni isteğe bağlı `launchIdlePauseRaw: String? = null` parametresi aldı (varsayılan `pause`), ama `DevKnobs` + `MainActivity` henüz geçirmiyor. Yapıldı (tek Spec satırı + tek alan + çağrıda bir argüman + DevKnobsTest): `DevKnobs.kt` içine `Spec("audio_idle_pause", Kind.STRING, debugOnly = true, ids = setOf("off", "pause", "stop"))` ve `val audioIdlePause: String? = null` + `audioIdlePause = x.string("audio_idle_pause")`; `MainActivity.kt:553` `AudioPlayout(this, {…}, gameSettings.audioOut, devKnobs.audioOut, devKnobs.audioBufBursts, devKnobs.audioIdlePause) {…}`. `--es audio_idle_pause off|pause|stop` artık çalışır.
2. **`docs/KNOBS.md` satırı (yeni):** `--es audio_idle_pause off|pause|stop`, varsayılan `pause`, `…/audio/IdlePause.kt`, T-287, yalnızca geliştirici (T-185 kapısı).
3. **`docs/LOGGING.md` yeni olaylar** (`audio`): `ev=idle_pause stream_id= api= mode= idle_s= state= pause_ms= count=` (I); `ev=idle_pause_failed stream_id= api= mode= code= state= pause_ms=` (W); `ev=resume stream_id= api= mode= ok=0|1 paused_ms= wake_ms= start_ms=` (I); `ev=resume_skipped stream_id= reason=rebuild paused_ms=` (I); `ev=first_sound stream_id= api= ms= idle_pause= pauses=` (I; ilk paketten ilk duyulur burst'ün yazılışına, bir boşluktan sonraki her yeniden başlamada ve akış başında); `ev=audio_idle_pause_unknown using=` (W); `ev=stats` yeni alan `idle_pauses=`; `ev=audio_device` yeni alan `idle_pause=off|pause|stop`.
4. `first_sound` çıkış arabelleğinin dinlenme gecikmesini (~`buf_frames`/48 ms) içermez; A/B'de iki kol aynı biçimde ölçüldüğü için karşılaştırılabilir.
5. AudioTrack çıkışı duraklatılmaz (kapsam: kart AAudio diyor; bu cihazda AAudio MMAP kullanılıyor). Gerekirse ayrı kart.
