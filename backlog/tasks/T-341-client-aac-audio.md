---
id: T-341
title: İstemci — AAC-LC ses çözme (MediaCodec) ve uzak oturumda AAC isteği
status: done
phase: 7
owner: android-client-dev
depends_on: [T-339]
decisions: [0038, 0011, 0012]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/
  - backlog/tasks/T-341-client-aac-audio.md
---

## Amaç

Karar 0038 §4; PROTOCOL.md AUDIO_*. Dal tabanı: `task/0038-remote-integration` (T-339 birleştikten sonra).

## Kapsam

1. HELLO bit14 `AUDIO_AAC`'yi yalnız cihaz `audio/mp4a-latm` çözücüsü bildiriyorsa yaz.
2. Uzak oturumda ses açıkken `AUDIO_PREFS.codec = 1`; normal oturumda `0` (PCM değişmez).
3. `AUDIO_CONFIG.format = 2`: `MediaCodec` AAC çözücüsü, `csd-0` = AudioSpecificConfig `sample_rate`/`channels`'tan (48 kHz stereo LC: `0x11 0x90`). Çözme ayrı bir iş parçacığında; okuyucu iş parçacığı asla bloklanmaz. Çıkan PCM bugünkü titreşim tamponuna (`sample_index`, `capture_time_us`) yazılır.
4. Geçersiz birim (`frame_count ≠ 1024`, `data_len` 0 ya da > 1536) atılır; çözücü hatasında akış yok sayılır ve bir kez loglanır (protokol hatası değil).
5. Uzak oturumda ses başlangıç tamponu en az 100 ms. 60 sn duraklatma (T-287) çalışmaya devam eder.
6. Akış durunca/oturum bitince çözücü serbest bırakılır.

## Kabul

- Birim testleri: AudioSpecificConfig türetme; bit14/codec seçimi; geçersiz birim atma.
- `./scripts/check.sh` geçer. Codex incelemesi (orta).
- Cihaz testi orkestratörde (uzak oturumda ses aç, YouTube 1 dk).

## Plan

1. `audio/AacRules.kt` (saf Kotlin): AudioSpecificConfig türetme (LC, tablo), birim doğrulama (`frame_count = 1024`, `data_len` 1..1536), `capabilityBits(audioAllowed, decoderAvailable)`.
2. `audio/AacUnitQueue.kt`: sınırlı (32 birim), en eskiyi atan kuyruk; okuyucu iş parçacığı yalnız `offer` yapar (bloklamaz).
3. `audio/AacDecodeWorker.kt` + `AacCodecPort` (arayüz) + `MediaCodecAacPort`: ayrı iş parçacığı; birim başına `pts = seq`; çıkış PCM `sample_index`/`capture_time_us` ile (AU'nun meta verisi, aynı AU'dan fazla çıkışta kare ofsetiyle) titreşim tamponuna yazılır. Hata: bir kez log, akış yok sayılır; çıkışta codec serbest.
4. `AudioStreamGate`: `format = 2` (48 kHz, 2 kanal) yalnız AAC çözücü varsa çalınabilir; `accepts` biçime göre (PCM: `frame_count*4`, AAC: `AacRules`).
5. `AudioPlayout`: AAC akışında worker; `onFrame` kuyruğa; `beginSession(..., remote)`: uzak oturumda güvenlik tamponu (başlangıç) >= 100 ms, bu değer SafetyMemory'ye kaydedilmez.
6. `RemoteProfile.audioPrefs(aac)`; `SessionMachine` `hello.capabilities` bit14'e bakar. `MainActivity.buildHello` bit14'ü yalnız cihaz çözücüsü varsa yazar.
7. Birim testleri: ASC, bit14/codec seçimi, geçersiz birim, kuyruk, worker (sahte codec), gate, uzak tampon.

## Handoff

- Dal: `task/T-341-client-aac-audio` (taban ff450dbe). Commit SHA: `git log -1` (son commit).
- Dosyalar: `audio/AacRules.kt` (ASC, birim doğrulama, bit14, `RemoteAudio`), `audio/AacUnitQueue.kt`, `audio/AacDecodeWorker.kt` (+ `AacCodecPort`, `MediaCodecAacPort`, `AacDecoderProbe`), `AudioStreamGate.kt`, `AudioPlayout.kt`, `session/RemoteProfile.kt`, `session/SessionMachine.kt`, `session/SessionController.kt` (log: `codec=`), `MainActivity.kt`; testler `AacRulesTest`, `AacUnitQueueTest`, `AacDecodeWorkerTest`, `AacPrefsMachineTest`.
- Davranış: bit14 yalnız ses açık ve cihazda `audio/mp4a-latm` çözücüsü varsa. Uzak oturumda ses açık ve bit14 varsa `AUDIO_PREFS.codec = 1`, aksi halde 0; normal oturum hep PCM. `format = 2` yalnız çözücü varsa çalınır (48 kHz, 2 kanal). Okuyucu iş parçacığı yalnız `AacUnitQueue.offer` yapar (32 birim, en eskiyi atar); çözme `mb-aac-<id>` iş parçacığında, PCM `core.buffer.write(sample_index, capture_time_us, ...)`. `capture_time_us` hiçbir zaman `sample_index`'ten türetilmez; bir AU birden fazla çıkış verirse sonrakiler kare ofsetiyle ilerler. Geçersiz birim (`frame_count != 1024`, `data_len` 0 / >1536) kapıda atılır. Çözücü hatası: `audio_aac_error` bir kez, akış susar; akış durunca / oturum bitince iş parçacığı çözücüyü bırakır. 60 sn duraklatma (T-287) değişmedi: `onPacket()` çözücü çıkışında çağrılır.
- Uzak oturum ses başlangıç tamponu: `beginSession(gen, transport, remote)`; uzakta jitter güvenliği en az 100 ms (taban ve tavan), öğrenilen değer SafetyMemory'ye yazılmaz, taşıma değişimi güvenliği değiştirmez.
- Varsayımlar: Android AAC çözücüsü AU başına 1024 kare verir ve kodlayıcı gecikmesini kendisi kırpmaz (host gecikmeyi `capture_time_us`'tan zaten düştü). `csd-0` = `0x11 0x90`. `MainActivity.remoteSession` artık `@Volatile` (motor iş parçacığı okuyor).
- Test edilmedi (cihaz gerekir): gerçek `MediaCodec` AAC çözme (T-340 host birleşince), A/V senkronu, 100 ms tampon hissi, `AacDecoderProbe` HarmonyOS'ta.
- Cihazda kontrol: uzak oturumda ses aç; log: `audio_prefs_sent ... codec=1`, `audio_config ... format=2`, `audio_start ... codec=aac remote=1`, `safety_start used=100`; `audio_aac_error` OLMAMALI; YouTube 1 dk boyunca underrun ve A/V kayması; normal oturumda `codec=pcm` ve davranış aynı.

- Codex düzeltmeleri (2 x P2): (1) çözücüye giriş verildikten sonra 300 ms boyunca girdi kuyruğu 5 ms'lik kısa poll'la beklenir ve çıkış hemen boşaltılır (250 ms'lik boşta poll'a takılmaz). (2) `AacDecodeWorker(previous=)`: yeni çözücü, önceki akışın çözücüsü serbest kalana kadar (en çok 1 sn) oluşturulmaz; `start` hata verirse bir kez 50 ms sonra yeniden denenir. Testler: geç çıkış, serbest bırakma sırası, tek yeniden deneme. `task/0038-remote-integration` birleştirildi.

- Codex tur 2 (2 x P2): işçi artık selefin yalnız bırakma mandalını (latch) tutar, işçiyi değil (zincirleme bellek sızıntısı yok); durdurulmuş işçi, selef beklemesinden ve yeniden deneme gecikmesinden sonra `running`'i kontrol eder ve çözücü hiç oluşturmaz. Testler eklendi.

## Open questions

- Yok. Codex incelemesi orkestratörde.
