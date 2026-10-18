---
id: T-354
title: Host — tablet kamerası: kamera bağlantısı, H.264 çözme, OBS sanal kameraya yazım, kullanım algılama
status: done
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

1. `obs-cam-probe --watch` (önce, ayrı commit `cdb585f8`): özellik değişimlerini zaman damgasıyla yazar; `--watch --pattern` birlikte çalışır.
2. Core: kodek (CameraMessages, Message/FrameDecoder `.camera`, bit15, `cameraKeys`), `CameraConnectionMachine` (kanıt/tek etkin bağlantı), `CameraController` (koşul tablosu, OFF'ta hiçbir kaynak yok), `CameraUsageTracker` (kullanım yoklaması), `CameraStreamGate` (kuyruk sınırı + keyframe isteği aralığı), `CameraKnobs`. Hepsi saf ve birim testli.
3. Host: `ObsVirtualCamera` (CMIO, dinleyici + sink), `H264CameraDecoder` + `CameraFrameScaler` (VT), `CameraConnectionService` (dinleyici, kayıt katmanı, çözme yolu), `CameraBridge` (oturum yapıştırıcısı, tek zamanlayıcı), menü maddesi (elle yedek), `--camera-selftest`.

## Handoff

- Commit'ler (dal `task/T-354-host-camera`, taban `76c877a8`): `cdb585f8` obs-cam-probe `--watch` (orkestratör kullanım algılama deneyini bununla erken yapabilir); `97107a21` Core (kodek, makineler, birim testleri); son commit: host katmanı + belgeler + bu kart.
- Dosyalar: `host-mac/Sources/MateBridgeCore/{Protocol/CameraMessages.swift, Message.swift, ProtocolConstants.swift, FrameDecoder.swift, Messages.swift (bit15), Crypto/KeySchedule.swift, Session/SessionMachine.swift, Input/InputStateMachine.swift (yalnız switch), Camera/*}`, `host-mac/Sources/MateBridgeHost/{Camera/*, Session/SessionServer.swift (cameraKeys)}`, `host-mac/Sources/MateBridgeApp/main.swift`, `host-mac/Tests/MateBridgeCoreTests/{FixtureTests, Crypto/CryptoVectorTests, Camera/*}`, `tools/obs-cam-probe/*`, `docs/{LOGGING,KNOBS}.md`, bu kart. `Package.swift` değişmedi (CoreMediaIO/VideoToolbox sistem çerçeveleri, bağımlılık yok).
- **Kullanım algılama sonucu (ölçüldü, bu makinede, 2026-10-18):** `obs-cam-probe --watch --pattern` ile: kendi sink yazımımız başlayınca OBS cihazının `DeviceIsRunningSomewhere` (`gone`) ve `IsRunning` (`goin`) **1 oluyor**, sink durunca 0'a düşüyor (gecikme ~5 ms, dinleyici bildirimleri geliyor). Yani host yazarken özellik "başka uygulama kullanıyor mu"yu söylemez. Kaynak akışın (dir 1) ve cihazın hiçbir başka özelliği yazım sırasında değişmedi (Direction/Latency/FrameRate sabit). Photo Booth ile hâlâ **denenmedi** (GUI yasak): orkestratör `--watch` ve `--watch --pattern` ile Photo Booth'u açıp kapatarak (a) yazmıyorken Photo Booth'un özelliği 1 yaptığını, (b) yazarken Photo Booth'un hiçbir özelliği değiştirmediğini doğrulamalı.
- **Algılama yaklaşımı:** başlama: yazmıyorken `IsRunningSomewhere` 0→1 (CMIO özellik dinleyicisi, zamanlayıcı yok) → hemen START. Bitiş: yazarken kullanım "sürüyor" varsayılır; her `MATEBRIDGE_CAMERA_PROBE_S` (varsayılan 15 sn) sink ~0,6 sn durdurulur (`CMIODeviceStopStream`) ve özellik okunur: hâlâ 1 ise başka istemci var, sink yeniden açılır; 0 ise uygulama bitti, sink kapalı kalır, `CameraController` 3 sn süzgeçten sonra STOP gönderir. Bedel: uygulamada her 15 sn'de ~0,6 sn donma ve en kötü bitiş gecikmesi ~15+0,6+3 sn. Yedek: Mac menüsünde "Tablet kamerası: kullanımda say (elle)" (yalnız AUTO iken görünür; açıkken kullanım sabit, yoklama kapalı). Deney kaynak akışta temiz bir sinyal bulursa yalnız `CameraUsageTracker`/`ObsVirtualCamera.write` değişir.
- Varsayımlar: OBS sink 1920x1080 BGRA 30 fps (T-351); farklı boyut/en-boy oranı `VTPixelTransferSession` ile ölçeklenir, oran farklıysa siyah şeritli (letterbox), esnetme yok; ön kamera aynası uygulanmaz; `facing` host'u ilgilendirmez; kamera portu 47004 (doluysa sistem portu), dual-stack, peer = kontrol peer'i; kayıt katmanı payload sınırı 4 MiB (`FrameDecoder.Connection.camera`); gizlilik: kare içeriği loglanmaz/yazılmaz, yalnız sayaçlar (`ev=camera_stats`).
- Doğrulanan (bu makinede, tablet/OBS çıktısı/kamera izni olmadan): `swift build` temiz, kamera fixture/kripto/birim testleri geçti (+53 test), `--camera-selftest` loopback uçtan uca: yanlış cam_id → REJECTED, kanıt öncesi CAM_FRAME → yalnız o bağlantı kapanır, kanıt sonrası STARTUP keyframe isteği, VideoToolbox'ın kendi H.264 kodlayıcısından 60/60 kare 1280x720 → 1920x1080 BGRA çözüldü ve ölçeklendi (30 fps), taşma sonrası keyframe isteği, keyframe ile toparlanma, servis kapanınca bağlantı kapanır. `check.sh --only host`: bkz. aşağıdaki not.
- **check.sh notu:** `BoundedWaitTests` (`timesOutWhenOperationNeverReturns`, `senderStopOnStuckTransportReturnsInTime`, kimi zaman `completesWhenOperationFinishes`) tam koşuda başarısız: bu makinede Android Studio/Gradle paralel çalışırken yükleyici; **dalın tabanında (`76c877a8`) kamera kodu olmadan da aynı testler aynı şekilde düşüyor**, tek başına koşunca geçiyor. Kameradan bağımsız, zamanlamaya duyarlı mevcut test. Yük yokken `./scripts/check.sh --only host` yeniden koşulmalı.
- Doğrulanmadı (orkestratör): gerçek OBS sink'ine akış ve Photo Booth/Zoom görüntüsü, gerçek tabletten H.264 (T-355 ile birlikte), `IsRunningSomewhere` davranışı Photo Booth ile, yoklama donmasının kullanıcıya görünürlüğü, sürenin uzun (saatlik) çalışması, arka plan/ön plan geçişi.
- Cihaz testi adımları: bkz. son rapor (orkestratöre) ve `obs-cam-probe/README.md` `--watch` bölümü.

## Open questions

- USB oturumu (loopback eş): kamera portu (47004 ya da sistem portu) `adb reverse` kümesinde değil (`UsbTunnelWatcher` yalnız 47001/47002), tablet host'a ulaşamaz. Şimdilik USB oturumunda `AUTO` → `UNAVAILABLE` gönderilir ve `ev=camera state=usb_not_supported` yazılır. Çözüm: sabit 47004 için `adb reverse` + doluysa reddetme; ayrı kart.
- PROTOCOL.md'de "START durumundayken 10 sn boyunca etkin kamera bağlantısı yoksa host STOP gönderebilir": uygulanmadı (STOP sonrası kullanım sürüyorsa hemen yeniden START olacağı için döngü riski). Tablet 3 denemeden sonra kamerayı kapatır; host dinleyicisi açık kalır ta ki kullanım biter.
- Kullanım bitişi yoklaması geçici çözüm (yukarıda); temiz sinyal bulunursa değiştirilecek. Varsayılan aralığın (15 sn) kullanıcı için kabul edilebilir olup olmadığı karar bekliyor.
- Menüdeki elle madde Türkçe metin ve yalnız AUTO iken görünür; kalıcı değil (oturum bitince tracker sıfırlanır, madde durumu korunur).
