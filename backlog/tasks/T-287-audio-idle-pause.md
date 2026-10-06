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

## Open questions
