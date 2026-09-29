---
id: T-014
title: Mac entegrasyonu — oturum + görüntü hattı, istatistik, uçtan uca akış
status: review
phase: 1
owner: mac-host-dev
depends_on: [T-010, T-011]
decisions: [0002]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/
  - host-mac/Sources/MateBridgeApp/
  - host-mac/Tests/
---

## Amaç

Onaylanan oturumda sanal ekranı açıp kareleri video bağlantısına akıtmak. Oturum bitince sanal ekranı kapatmak (kısa kopmalarda bekleme süresiyle, NOTES 2026-09-29).

## Kabul kriterleri

- [x] ACCEPTED → sanal ekran (tabletin `HELLO` çözünürlüğü) → `STREAM_CONFIG` → video akışı. `KEYFRAME_REQUEST` kodlayıcıya iletilir.
- [x] Kopmada sanal ekran **10 sn** bekler; aynı cihaz geri gelirse aynı ekran kullanılır, gelmezse kapanır.
- [x] `STATS` alınır: menüde ve `host.log`'da FPS, bitrate, gecikme.
- [x] Soket yetişemezse video kuyruğu kuralı (§5) uygulanır. Bellek şişmez.
- [x] `./scripts/check.sh` geçiyor.

## Plan

1. Core (saf, testli): `VideoSettings.forTablet(hello)` (HELLO çözünürlüğü, HEVC), `DisplayLease` (10 sn bekleme), `VideoSender` + `VideoTransport` (2 uçuş geri basıncı, `frame_seq` gönderimde), `StatsSummary`, `RotatingLogFile` (host.log).
2. Host: `StreamCoordinator` (sıralı olay akışı: oturum -> `VideoPipeline` -> `VideoLink`; KEYFRAME_REQUEST, STATS, tick), `HostClock`, `SessionLogger` dosyaya da yazar.
3. App: koordinatörü bağla, menüde video/istatistik satırı, çıkışta `shutdown`.

## Handoff

- **Commit:** bkz. `git log task/T-014-host-integration`
- **Dokunulan dosyalar:** Host: `Session/{StreamCoordinator,HostClock,SessionLogger,SessionServer}.swift`; App: `main.swift`; Core (yeni dosyalar, aşağıya bak): `Video/{StreamSettings,DisplayLease,VideoSender,StatsSummary}.swift`, `Session/RotatingLogFile.swift`; Tests: `Video/IntegrationTests.swift`; bu kart.
- **Varsayımlar:**
  - STREAM_CONFIG artık gerçek: HEVC, tabletin HELLO piksel boyutu (nokta = piksel/2), fps = min(tablet Hz, 60), 30 Mbit/s, config_id=1, sRGB/BT.709/tam aralık. Geçersiz HELLO boyutu (0, tek sayı, >4096) 2800x1840'a düşer. `SessionServer.defaultStreamConfig` artık kullanılmıyor (App `makeStreamConfig` veriyor).
  - Sanal ekran ACCEPTED'de (sessionStarted) kurulur; STREAM_CONFIG ekran kurulmadan gönderilir. Oturum bitince 10 sn boyunca (aynı cihaz + aynı ayar) ekran ve boru hattı çalışır kalır, kareler çöpe atılır (kuyruk şişmesin); yeni tüketici `prepareForNewConsumer` ile CODEC_CONFIG + keyframe alır.
  - Cihaz kimliği `makeStreamConfig(hello)` çağrısından alınır (makine bunu hemen `sessionStarted`'dan önce çağırır); `SessionAction.sessionStarted`'a deviceID eklemek yerine bu seçildi (Core/Session mevcut dosyalarına dokunulmasın).
  - Gönderici yalnızca `canSend` iken kare çeker; kuyruk (2 kare) taşmayı kendisi atar, `frame_seq` gönderimde atanır. Gönderim hatasında (`completion(false)`) gönderici biter, boru hattı çalışmaya devam eder ve tüketici çöp kuyruğuna döner. İstemci video bağlantısını yeniden açınca yeni gönderici kurulur.
  - Saat: `HostClock.nowUs()` (`CMClockGetHostTimeClock`) hem oturum makinesinin `now`'ı (PONG `responder_time_us`) hem yakalama saati ile aynı; eskiden `DispatchTime` idi.
  - `host.log`: `~/Library/Logs/MateBridge/host.log`, 5x10 MB, 0600/0700; `SessionLogger` hem os.Logger hem dosyaya yazar (debug seviyesi dosyaya yazılmaz). Encoder/capture hâlâ yalnızca os.Logger kullanıyor.
  - STATS her geldiğinde `component=net ev=stats` satırı (fps, kbps, decode_ms, dropped, latency_ms + host tarafı sent_frames/sent_kbps/rejected) ve menüde "58 fps · 30.0 Mbit/s · 35 ms".
  - Ekran Kaydı izni yok / ekran kurulamadı: çökme yok, menüde "Video başlamadı: ..." yazar; kontrol oturumu açık kalır (istemciye ayrı bir hata mesajı yok, PROTOCOL'de karşılığı yok).
- **Test edilmeyenler / cihazda doğrulanacaklar:** Yalnızca Core birim testleri (ayar, lease, gönderici geri basıncı/sıra/hata/durdurma, stats, log rotasyonu) ve derleme; `check.sh` ALL OK. Uygulama çalıştırılmadı. Cihazda: (1) bağlan -> Mac'te sanal ekran, tablette HEVC görüntü; `host.log` içinde `display_created`, `video_streaming`, `stats`. (2) Tableti/Wi-Fi'ı 3-5 sn kes, geri gelince `display_reused` ve pencereler yerinde; 12+ sn keserse `display_teardown`. (3) Başka cihaz/çözünürlükle bağlanınca `display_teardown` + yeni ekran. (4) Durağan ekranda yeniden bağlanınca ilk kare geliyor mu (keyframe zorlaması). (5) Çıkışta (Quit) sanal ekran kalkıyor mu. (6) Ekran Kaydı izni yokken menü mesajı. (7) Ağ yavaşlatılınca `frames_dropped` artıp keyframe isteği, bellek sabit mi. (8) `KEYFRAME_REQUEST` sonrası akış toparlanıyor mu. (9) Latency gösterimi: PING/PONG saat farkı ile ms mantıklı mı.
- **Açık sorular:**
  - Kart `files:` listesinde Core yok, ama saf mantık için `MateBridgeCore/Video/` ve `Session/` altına yalnızca YENİ dosyalar ekledim (mevcut Core dosyalarına dokunulmadı): AGENTS.md "donanımsız mantık Core'da + testli" kuralı ve Package.swift'e Host test hedefi eklenemediği için. Orkestratör onayladı, `files:` güncellendi.
  - Video başlatma başarısız olursa (izin yok) istemciye bildirme yolu yok; kontrol oturumu açık, video gelmez. PROTOCOL'e bir hata/BYE nedeni eklenmeli mi?
  - Kopma sırasında boru hattı 10 sn boşuna kodluyor (çöp tüketici). İstenirse yakalama duraklatılabilir, ama durağan ekranda bayat keyframe riski var.
  - Bitrate/fps kullanıcıya açık değil (sabit 30 Mbit/s, 60 fps).

## Review düzeltmeleri (2. commit)

Olay kuyruğu sınırlı (`BoundedMailbox`: STATS/KEYFRAME_REQUEST/tick birleştirilir, yaşam döngüsü olayları en çok 16, taşarsa `SessionServer.endSessions()` ile oturumlar kapanır); sender/pipeline sonunda video bağlantısı `cancel()` edilir, canlı oturumda pipeline hatasında 1 sn bekleyip bir kez yeniden kurulur; gönderim hatası `detachConsumer` ile bekleyen döngüyü uyandırır; `host.log` ayrı seri kuyrukta, 2048 satırlık sınırlı tampon (taşan en eski satırlar atılır, sayılır ve `dropped_lines` satırı yazılır); fps = min(tablet Hz, 60) (0 ise 60); `shuttingDown` bayrağı; log dosyası/dizin izinleri sıkılaştırılır; HELLO boyutundan farklı ekran için uyarı; reddedilen kare sonrası keyframe isteği 500 ms'de bir. Commit: bkz. `git log task/T-014-host-integration` (ilk commit 5656ea1, düzeltme commit'i üstünde).
