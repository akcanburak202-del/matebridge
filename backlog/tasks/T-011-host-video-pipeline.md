---
id: T-011
title: Mac görüntü hattı — sanal ekran, yakalama, HEVC kodlama, sınırlı kuyruk
status: review
phase: 1
owner: mac-host-dev
depends_on: [T-008]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
---

## Amaç

Sanal ekrandan `VIDEO_FRAME` mesajlarına kadar olan hat. Ağa bağlanmaz: çıkışı sınırlı bir kuyruk/sink arayüzüdür; T-014 oturumla bağlar.

## Kabul kriterleri

- [ ] `VirtualDisplay.swift`: `probes/vdisplay-probe`'daki çalışan yaklaşımın ürün sürümü (HiDPI'da yalnız nokta boyutlu mod, NOTES 2026-09-29). Private API yalnızca bu dosyada.
- [ ] ScreenCaptureKit → VideoToolbox **HEVC** (düşük gecikme: real-time, B-frame yok, ayarlanabilir bitrate/FPS, keyframe isteğe bağlı) → Annex-B. İlk çıktı `CODEC_CONFIG`, sonra keyframe. Renk etiketleri `STREAM_CONFIG` ile tutarlı (sRGB/BT.709, tam aralık).
- [ ] Kodlayıcı → sink arasında en çok 2 kare (PROTOCOL.md §5). Politika saf ve `MateBridgeCore/Video`'da birim testli: taşmada eski keyframe olmayan kareler atılır, sonraki kare keyframe istenir.
- [ ] `requestKeyframe()`, `STREAM_CONFIG` değerlerini üreten yapı, temiz durdurma (sanal ekran ve akış kapanır).
- [ ] Doğrulama aracı: `MateBridgeApp --dump-video <dosya> --seconds N` (veya ayrı bir alt komut) Annex-B `.h265` dosyası yazar ve kare sayısı / ortalama boyut / keyframe sayısı / kodlama süresi yazdırır. Bu dosya T-013'te tablette çözme testi için kullanılacak.
- [ ] Ekran Kaydı izni yoksa anlaşılır hata, çökme yok.
- [ ] `./scripts/check.sh` geçiyor.

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
- **Açık sorular:**
