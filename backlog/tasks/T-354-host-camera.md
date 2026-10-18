---
id: T-354
title: Host — tablet kamerası: kamera bağlantısı, H.264 çözme, OBS sanal kameraya yazım, kullanım algılama
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-351]
decisions: [0040]
files:
  - host-mac/Sources/
  - host-mac/Tests/
  - host-mac/Package.swift
  - tools/obs-cam-probe/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-354-host-camera.md
---

## Amaç

Karar 0040 (ek 2026-10-18) ve PROTOCOL.md'deki kamera bölümü (dal `task/T-353-camera-protocol`, commit 5b1b9b49: 0x0E CAMERA_PREFS, 0x0F CAMERA_CONTROL, "Kamera bağlantısı", 0x60–0x63, bit15, §5 Kamera, §9 kamera anahtarları). Protokol orkestratörün; değişiklik gerekirse kodlama, Open questions'a yaz.

## Kapsam

1. **Kodek:** dört kamera bağlantısı mesajı + iki kontrol mesajı, Swift kodlama/çözme, bütün yeni fixture'lar ve `crypto_vectors.json` kamera anahtarları/kayıtları fixture testlerinde (mevcut kalıp).
2. **Kullanım algılama (önce dene):** Mac'te bir uygulama OBS sanal kamerasını kullanıyor mu? Aday: OBS cihazında `kCMIODevicePropertyDeviceIsRunningSomewhere` (+ özellik dinleyicisi), gerekirse kaynak akışın (`direction = 1`) özellikleri. **Kritik soru:** host'un kendi sink yazımı bu özelliği "çalışıyor" tutuyor mu? Tutuyorsa kullanım bitişi nasıl anlaşılır (ör. yazım sırasında da değişen başka bir özellik)? Bunun için önce `tools/obs-cam-probe`'a `--watch` modu ekle (özelliği ve değişimlerini zaman damgasıyla yazar; `--watch --pattern` birlikte de çalışabilsin). Orkestratör kullanıcıyla Photo Booth açıp kapatarak dener. Sonucu Handoff'a yaz; algılama mümkün değilse Open questions'a "yedek: Mac menüsünde elle aç/kapat" yaz ve onu uygula.
3. **CameraController (oturum başına):**
   - Durum: son `CAMERA_PREFS` (mode, facing), oturumun `link`'i, OBS cihazı var mı, kullanım var mı (süzgeç: başlama hemen, bitiş 3 sn).
   - AUTO + yerel + cihaz + kullanım → dinleyiciyi aç (47004, doluysa sistem portu), yeni `cam_id`, `CAMERA_CONTROL(START, 1920×1080, 30, 6000)`. Koşul düşünce `STOP`, dinleyici ve bağlantı kapanır. AUTO + cihaz yok → `UNAVAILABLE` (değişince bir kez).
   - Bit15 yoksa hiçbir şey yapma. Mode OFF iken hiçbir CMIO dinleyicisi, zamanlayıcı ya da dinleyici soket **çalışmaz** (OFF'tan AUTO'ya geçince kurulur, geri dönünce sökülür).
4. **Kamera bağlantısı:** PROTOCOL'deki 9 maddenin hepsi: kanıtlanmamış ≤ 1, 5 sn, eş adres = kontrol eş adresi, session_id/cam_id denetimi, iki nonce ile anahtarlar, ilk kayıt PING kanıtı, tek etkin bağlantı (kanıt gelince eskisi kapanır), geçersiz tip/yön → yalnız kamera bağlantısı kapanır, oturum sonunda her şey kapanır. Mevcut dosya bağlantısı kodundaki kalıpları yeniden kullan (ayrı tip, kopyala-yapıştır değil, gerekiyorsa ortak yardımcı).
5. **Çözme ve yazım:** VTDecompressionSession (H.264, CODEC_CONFIG ile kur/yeniden kur) → BGRA, OBS sink'in beklediği boyuta (1920×1080, T-351 Handoff) gerekirse VTPixelTransferSession ile ölçekle → CMSampleBuffer → `CMSimpleQueueEnqueue` (T-351 aracındaki sıra: cihaz UUID'si OBS plist'inden, sink = `direction == 0` akışı, `CMIOStreamCopyBufferQueue`, `CMIODeviceStartStream`; durunca `CMIODeviceStopStream`). Kuyruklar §5: çözücü ≤ 2 bekleyen, taşınca at + `CAM_KEYFRAME_REQUEST(FRAMES_DROPPED)` (500 ms aralık), çözme hatası → `DECODE_ERROR`, sink kuyruğu dolu → kareyi at ve say.
6. **Gizlilik ve log:** kare içeriği asla loglanmaz/yazılmaz. `docs/LOGGING.md` biçiminde olay satırları: `ev=camera state=start|stop|unavailable cam_id= reason=`, bağlantı kabul/ret, 10 sn'lik özet (alınan/çözülen/yazılan/düşen kare, fps). `docs/KNOBS.md`'ye varsa yeni ortam değişkeni.
7. Girdi, video ve ses yolları değişmez. `VirtualDisplay`'e dokunma. Yeni bağımlılık yok (yalnız CoreMediaIO/VideoToolbox/CoreMedia).

## Kabul

- Fixture ve kripto testleri (Swift) yeşil; CameraController için birim testleri (koşul tablosu, OFF'ta hiçbir kaynak yok, UNAVAILABLE tek sefer, cam_id artışı, oturum sonu temizliği); kamera bağlantısı el sıkışma testleri (yanlış session/cam_id, eş adres, kanıtsız kare, ikinci kanıtlanmamış bağlantı, eski bağlantının yalnız kanıttan sonra kapanması). CMIO/VT kısmı arabirim arkasında, testte sahte.
- `./scripts/check.sh` host kısmı geçer (Android kısmı paralel kartta, T-355; `--only host` kullan).
- Cihaz testi orkestratörde. Mac'te pencere açma; kamera izni isteme.

## Plan

## Handoff

## Open questions
