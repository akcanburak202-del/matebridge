---
id: T-340
title: Host — AAC-LC ses kodlama (AUDIO_PREFS.codec = 1 ve HELLO bit14)
status: done
phase: 7
owner: mac-host-dev
depends_on: [T-337]
decisions: [0038, 0011]
files:
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Sources/MateBridgeHost/Audio/
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift  # orchestrator-approved 2026-10-11 (audio queue accounting, review fixes)
  - host-mac/Sources/MateBridgeApp/main.swift  # orchestrator-approved (codec wiring)
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

### Review fixes (Codex round 1)

- Integration branch merged (ff450dbe); full `check.sh` ALL OK (Kotlin included).
- Timestamps: `capture_time_us` of each AU is now anchored to the real capture time of the PCM packet holding the AU's first decoded frame (source index `first + k*1024 - priming`, interpolated at 48 kHz inside the packet; extrapolated backwards only before the first packet). No accumulation of clock skew. Test: 100 ppm skew over 40 s. `sample_index` stays continuity-only (comments/tests say so, matching PROTOCOL.md).
- Segment end: after completing the partial block, zeros for `ceil(priming/1024)` blocks are fed so the audio inside the encoder comes out, then reset. Test updated (5 units before reset).
- Queue limits time-based for AAC: `AudioOutbox` drops oldest frames beyond 4800 sample frames (100 ms; AAC keeps 4 units, PCM still 10). `SessionServer.drainAudio` (minimal edit, Session/): user-space limit is `backlogFrames(frameCount) * frameSize`, and the control socket's `TCP_NOTSENT_LOWAT` is set at AUDIO_CONFIG(STARTED) from the codec (AAC about 3 nominal AUs = 915 B vs PCM 9 packets). `isStale` allows 66 ms extra for AAC units (their time is the first decoded frame, earlier by priming + own length). Tests in AudioOutboxTests. Pairing/HELLO_ACK paths untouched.
- Not verified on hardware: kernel unsent mark behaviour with AAC on a real Wi-Fi link.

### Review fixes (Codex round 2)

- Integration branch merged again (T-338 included); full `check.sh` ALL OK.
- User-space queue (`SessionServer.drainAudio`): `audioInflightFrames[id]` counts AUDIO_FRAME sample frames not yet handed to the kernel (decremented in `sendControl`'s `done`, cleared with the connection); a frame is dropped beyond 4800 (100 ms). The byte limit stays only as a backstop (`audioBacklogBytes`). No longer depends on the incoming AU's size. Not unit-tested (Host module has no test target); the outbox time budget is tested with alternating 256 B / 6 B units.
- Kernel mark: AAC `TCP_NOTSENT_LOWAT` is a fixed 1 KB (`AudioOutbox.aacNotSentLowatBytes`); comment states it is byte-bounded only, tiny units are near silence, the client's 300 ms jitter cap is the upper bound (PROTOCOL.md 5). PCM mark unchanged.
- `setNotSentLowat` now runs after the session-validity guard, so an obsolete session's STARTED cannot change the live socket.

## Open questions

- Index/zaman priming farki yukaridaki gibi; PROTOCOL.md AUDIO_FRAME'de sample_index anlami "blok ilk giris karesi (priming dusulmemis)" diye yazilmali mi (orkestrator karari).
