---
id: T-341
title: İstemci — AAC-LC ses çözme (MediaCodec) ve uzak oturumda AAC isteği
status: todo
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

## Open questions
