---
id: T-340
title: Host — AAC-LC ses kodlama (AUDIO_PREFS.codec = 1 ve HELLO bit14)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-337]
decisions: [0038, 0011]
files:
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Tests/
  - backlog/tasks/T-340-host-aac-audio.md
---

## Amaç

Karar 0038 §4; PROTOCOL.md AUDIO_PREFS/CONFIG/FRAME. Dal tabanı: `task/0038-remote-integration` (T-337 birleştikten sonra).

## Kapsam

1. Bit14 + `codec = 1` iken `AudioConverter` ile AAC-LC 48 kHz stereo, 96 kbps; her `AUDIO_FRAME` bir ham erişim birimi (ADTS yok), `frame_count = 1024`, `AUDIO_CONFIG.format = 2`, `frames_per_packet = 1024`. Aksi halde bugünkü PCM.
2. Kodlama gerçek zamanlı IOProc'ta **değil**; `AudioStreamer` kuyruğunda ya da ayrı bir aşamada. Kuyruk sınırları (§5, 100 ms) korunur.
3. `sample_index`/`capture_time_us`: biriminin çözülünce verdiği ilk kareye ait; kodlayıcı gecikmesi (priming) düşülür; birimler arası +1024.
4. Kodek değişimi (codec 0↔1) yeni `stream_id` ile akışı yeniden başlatır. Sessizlik kapısı (T-279) AAC'de de çalışır.
5. Kodlayıcı kurulamazsa PCM'e düşer ve bir kez loglar.

## Kabul

- Birim testleri: kodek seçimi (bit14 yok → PCM; codec 0 → PCM); erişim birimi zaman damgası aritmetiği; kodek değişiminde stream_id artar.
- Gerçek `AudioConverter` ile bir sinüs kodla → AU boyları 1–1536 arasında, ortalama ~96 kbps.
- `./scripts/check.sh` geçer. Codex incelemesi (orta).

## Plan

- Capture/IOProc yok sayilir: ring bugunku gibi 480 kare PCM paketleri tasir. AAC kodlama `AudioStreamer` kuyrugunda (drain), IOProc disinda: sessizlik kapisindan gecen her PCM paketi `AACStage`e verilir, 1024 karelik bloklar `AudioConverter` ile kodlanir, her AU bir `AUDIO_FRAME` (frame_count 1024).
- `AACStage` (Core, saf mantik + `AACConverting` protokolu): birikim, bosluk (kapi atlamasi/HAL bosluk) isleme (kucuk bosluk sifirla doldurulur, buyuk bosluk: kismi blok sifirla tamamlanip kodlanir + converter reset), zaman damgasi: AU k sample_index = segment ilk index + k*1024, capture_time = ilk karenin zamani + (k*1024 - priming)/48k. `AudioToolboxAACConverter` gercek AudioConverter (96 kbps, AAC-LC).
- `AudioStreamPolicy`: oturumda `clientSupportsAAC` (HELLO bit14) ve `prefs.codec`; istenen kodek degisince mevcut akis STOPPED ile biter, yeni stream_id ile yeniden baslar; kodlayici kurulamaz/bozulursa `aacEncoderFailed` -> PCM'e duser, bir kez loglanir.
- Kablolama: `AudioStreamer.sessionStarted/prefs` yeni parametreler (varsayilanli), `main.swift`'te iki satir.
- Testler: kodek secimi, stream_id artisi, zaman damgasi aritmetigi (sahte converter), gercek sinus kodlama (AU boy 1-1536, ~96 kbps).

## Handoff

- Commit: son commit "T-340: host AAC-LC audio encoding" (dal task/T-340-host-aac-audio).
- Dosyalar: Core/Audio: `AACStage.swift` (yeni; birikim, bosluk, zaman damgasi), `AudioToolboxAACConverter.swift` (yeni; AudioConverter, 96 kbps CBR, AAC-LC), `AudioStreamPolicy.swift` (clientSupportsAAC, codec, `activeCodec`, `aacEncoderFailed`, kodek degisiminde yeniden baslatma), `AudioStreamer.swift` (kodlama drain'de, `Options.makeConverter`). Tests: `AACAudioTests.swift` (yeni, 10 test). Kart disi tek degisiklik: `host-mac/Sources/MateBridgeApp/main.swift` iki satir (HELLO bit14 ve `prefs.codec` AudioStreamer'a iletiliyor; Session/ ve pairing/HELLO_ACK yollarina dokunulmadi).
- Tasarim: IOProc/ring degismedi (480 karelik PCM). Kodlama streamer kuyrugunda, sessizlik kapisindan sonra; 100 ms kuyruk siniri giris tarafinda ayni.
- Zaman damgasi (istemci icin onemli): AU k `sample_index = segment ilk PCM index + k*1024` (priming ile KAYDIRILMAZ; unsigned kalsin diye), `capture_time_us = ilk karenin zamani + (k*1024 - priming)/48000` (priming ~2112 kare = 44 ms dusulur). Yani index ile zaman arasinda sabit priming farki var. Sessizlik kapisi atlamasi/HAL boslugu: <=4096 kare sifirla doldurulur (segment surer); daha uzunsa kismi blok sifirla tamamlanip kodlanir, converter reset, yeni segment (sample_index bosluk kadar atlar).
- Sessizlik kapisi AAC'de de calisir (PCM paketi seviyesinde). Kodek degisimi (0<->1) STOPPED + yeni stream_id. Kodlayici kurulamaz/hata verirse PCM'e duser, `audio_aac_unavailable` bir kez loglanir (surec boyunca PCM).
- Varsayimlar: AudioConverter her 1024 karelik girdiye 1 AU verir (gercek sinus testi dogruladi: 1-1536 B, ort. ~96 kbps CBR). CBR modu en iyi caba.
- Test edilmedi: gercek tablet/istemci kod cozumu, gercek sistem ses tap'i ile uzun sure calisma, CPU maliyeti.
- check.sh: Swift gecti; Kotlin fixture-coverage testi beklendigi gibi basarisiz (T-339). Not: `ControlSocketTests.testLargeAndSmallRecordsKeepOrder` (XCTest) yuk altinda bir kez titreme gosterdi, tekrarda gecti; bu gorevle ilgisiz.

## Open questions

- Index/zaman priming farki yukaridaki gibi; PROTOCOL.md AUDIO_FRAME'de sample_index anlami "blok ilk giris karesi (priming dusulmemis)" diye yazilmali mi (orkestrator karari).
