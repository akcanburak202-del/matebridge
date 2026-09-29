---
id: T-011
title: Mac görüntü hattı — sanal ekran, yakalama, HEVC kodlama, sınırlı kuyruk
status: done
phase: 1
owner: mac-host-dev
depends_on: [T-008]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - host-mac/Sources/MateBridgeApp/   # orkestratör onayıyla: yalnız yeni DumpVideoCommand.swift + main.swift içinde 1 satır (--dump-video)
---

## Amaç

Sanal ekrandan `VIDEO_FRAME` mesajlarına kadar olan hat. Ağa bağlanmaz: çıkışı sınırlı bir kuyruk/sink arayüzüdür; T-014 oturumla bağlar.

## Kabul kriterleri

- [x] `VirtualDisplay.swift`: `probes/vdisplay-probe`'daki çalışan yaklaşımın ürün sürümü (HiDPI'da yalnız nokta boyutlu mod, NOTES 2026-09-29). Private API yalnızca bu dosyada.
- [x] ScreenCaptureKit → VideoToolbox **HEVC** (düşük gecikme: real-time, B-frame yok, ayarlanabilir bitrate/FPS, keyframe isteğe bağlı) → Annex-B. İlk çıktı `CODEC_CONFIG`, sonra keyframe. Renk etiketleri `STREAM_CONFIG` ile tutarlı (sRGB/BT.709, tam aralık).
- [x] Kodlayıcı → sink arasında en çok 2 kare (PROTOCOL.md §5). Politika saf ve `MateBridgeCore/Video`'da birim testli: taşmada eski keyframe olmayan kareler atılır, sonraki kare keyframe istenir.
- [x] `requestKeyframe()`, `STREAM_CONFIG` değerlerini üreten yapı, temiz durdurma (sanal ekran ve akış kapanır).
- [x] Doğrulama aracı: `MateBridgeApp --dump-video <dosya> --seconds N` (veya ayrı bir alt komut) Annex-B `.h265` dosyası yazar ve kare sayısı / ortalama boyut / keyframe sayısı / kodlama süresi yazdırır. Bu dosya T-013'te tablette çözme testi için kullanılacak.
- [x] Ekran Kaydı izni yoksa anlaşılır hata, çökme yok.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. Core/Video (saf, testli): `EncodedVideoFrame`, `BoundedFrameQueue` (kapasite 2 politikası), `AnnexB` (HVCC -> Annex-B), `VideoSettings` (+ `STREAM_CONFIG` üretimi, sRGB/BT.709/tam aralık), `VideoStats`.
2. Host/Video: `HEVCEncoder` (VT, low-latency, B-frame yok, isteğe bağlı keyframe), `ScreenCapture` (SCK, 420 full range, izin ön kontrolü), `VideoFrameQueue` (kilitli sink), `VideoPipeline`, `VideoDump`.
3. `VirtualDisplay.swift`: probe sürümünün ürün hali.
4. `--dump-video`: MateBridgeApp'e tek yeni dosya (`DumpVideoCommand.swift`) + main.swift'te 1 satırlık çağrı.

## Handoff

- **Commit:** bkz. `git log task/T-011-video-pipeline`
- **Dokunulan dosyalar:** `Sources/MateBridgeCore/Video/*`, `Sources/MateBridgeHost/Video/*`, `Sources/MateBridgeHost/VirtualDisplay.swift`, `Tests/MateBridgeCoreTests/Video/VideoTests.swift`. Kart dışı (orkestratör onayıyla): `Sources/MateBridgeApp/DumpVideoCommand.swift` (yeni) ve `Sources/MateBridgeApp/main.swift` içine tek satır `DumpVideoCommand.runIfRequested()` (T-010 ile birleştirirken çakışabilir; satır importlardan hemen sonra).
- **Varsayımlar:** `frame_seq` kodlayıcıda değil oturumda (T-014) atanır (`EncodedVideoFrame.toVideoFrame(seq:)`), böylece atılan karelerde boşluk olmaz. CODEC_CONFIG ilk çıktıda ve parametre setleri değişince gelir; yeni tüketici için `VideoPipeline.prepareForNewConsumer()` config'i yeniden kuyruğa koyar ve keyframe ister. Kuyruk taşmasında yalnız en eski keyframe-olmayan kare atılır ve keyframe istenir; sonraki delta karelerin istemci tarafında (PROTOCOL §5) yok sayılması beklenir. Kodlayıcıda en çok 3 kare uçuşta, fazlası yakalamada atlanır. Varsayılan 60 fps / 30 Mbps, `VideoSettings` ile ayarlanır. Kullanım: `--dump-video <dosya> --seconds N [--fps F] [--bitrate-kbps K]`.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Yalnızca Core birim testleri ve derleme çalıştırıldı. Sanal ekran, SCK, VideoToolbox hiç çalıştırılmadı (izin/ekran oluşturma yasaktı). Orkestratör: bundle + `--dump-video ~/x.h265 --seconds 5`; kare sayısı, keyframe>=1, dosyanın ffprobe/ffplay ile açılması, LowLatencyRateControl'ün HEVC'de M6'da kabulü, `TransferFunction=sRGB` özelliğinin VT'de kabulü (set hatası yutuluyor, VUI'yi doğrulayın), SCK'nın 420 full range + `colorMatrix` ile kare vermesi, izin yokken temiz hata mesajı. Statik ekranda SCK az kare üretir.
- **Gözden geçirme düzeltmeleri (cihaz testi + Codex sonrası):**
  - Statik ekran: son `CVPixelBuffer` tutulur; `requestKeyframe()` / `prepareForNewConsumer()` onu yeni PTS ile zorunlu keyframe olarak yeniden kodlar; bekleyen keyframe isteği ~1 sn boşta kalırsa da aynısı olur.
  - Yeni tüketici: kuyruk sıfırlanır, yalnız `[CODEC_CONFIG, keyframe, ...]` görür (eski delta kareler reddedilir). `VideoFrameQueue` Core'a taşındı; iptal/`detachConsumer()` bekleyeni serbest bırakır, testli.
  - Kodlayıcı: kilit + `stopped` bayrağı, en yeni kare kazanır (tek `pending`), `maxInFlight=2` (yukarıdaki "3" eskidi), SCK `queueDepth=5`, art arda 5 hata `onFailure`'a gider; `VTSessionSetProperty` hataları loglanır ve dump'ta yazılır.
  - Pipeline: `start` bir kez (`alreadyStarted`), `stop` idempotent, yakalama/kodlayıcı hatasında kendini kapatıp `onFailure` çağırır.
  - Dump: dosya kodlayıcı tap'inden yazılır (delik yok), yazma hatası çıkış kodu 3; SPS VUI'si ayrıştırılıp STREAM_CONFIG ile karşılaştırılır (uyuşmazlık çıkış kodu 4). `HEVCSPS` ayrıştırıcısı Apple'ın gerçek SPS'i ile test edildi.
  - `VirtualDisplay` oluşturulunca HiDPI modunu `CGDisplaySetDisplayMode` ile seçer (cihazda doğrulanmadı).
  - **T-014 için:** `captureTimeUs` host zaman saatidir (`CMClockGetHostTimeClock` = mach absolute time, µs). PING/PONG `sender_time_us`/`responder_time_us` aynı saati kullanmalı (PROTOCOL §6 saat farkı hesabı).
- **Açık sorular:**

## Orkestratör cihaz testi (2026-09-29)

`--dump-video` 5 sn: 100 kare, 1 keyframe, kodlama ort. 14 ms. Bit akışındaki SPS VUI: full_range=true, 1/13/1, STREAM_CONFIG ile eşleşiyor. `PrioritizeEncodingSpeedOverQuality` M6'da desteklenmiyor (-12900, zararsız). İlk sürümün dökümü tablette 0 atmayla çözüldü (T-013 notu). Durağan ekranda istek üzerine keyframe ve CGDisplaySetDisplayMode yolu cihazda ayrıca tetiklenmedi.
