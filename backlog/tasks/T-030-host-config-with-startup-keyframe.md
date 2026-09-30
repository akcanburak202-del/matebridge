---
id: T-030
title: Mac — STARTUP/DECODE_ERROR keyframe isteğinde CODEC_CONFIG'i yeniden gönder (hızlı yeniden bağlanmada siyah ekran)
status: review
phase: 2
owner: mac-host-dev
depends_on: [T-014]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Tests/
  - backlog/tasks/T-030-host-config-with-startup-keyframe.md
---

## Amaç

T-028: tablet, sanal ekranın 10 sn'lik bekleme süresi içinde yeniden bağlanırsa (`display_reused`) hiç kare çözemiyor (siyah ekran; 3/3 tekrarlandı, NOTES 2026-09-30).

Kök neden (log + kod okuması; düzeltmeyle doğrulanacak):

1. Yeniden kullanılan ekranda kodlayıcı zaten çalışıyor. Yeni video bağlantısına host hemen `[CODEC_CONFIG, keyframe]` gönderiyor (`VideoPipeline.prepareForNewConsumer`), birkaç ms içinde.
2. Tablet `STREAM_CONFIG`'i UI iş parçacığında biraz **sonra** uyguluyor (`VideoRenderer.reconfigure` → `queue.reset(STARTUP, keepConfig = false)`): o ana kadar gelmiş `CODEC_CONFIG` ve keyframe atılıyor, `KEYFRAME_REQUEST(STARTUP)` gönderiliyor (host log'unda `video_streaming`'den ≈50 ms sonra `keyframe_request reason=0`).
3. Host isteğe yalnızca keyframe ile cevap veriyor. Parametre setleri değişmediği için `HEVCEncoder.handle` `CODEC_CONFIG` üretmiyor (`changed == false`). Tablet config'siz keyframe'leri çözücüye veriyor: `recv>0 dec=0`, `output_format` yok.

Yeni ekranda sorun yok, çünkü kodlayıcı yeni ve ilk karesi tabletin reset'inden sonra çıkıyor (config "değişmiş" sayılıp gönderiliyor).

## Kabul kriterleri

- [ ] `KEYFRAME_REQUEST` sebebi `STARTUP`, `DECODE_ERROR` ya da bilinmeyen ise host, zorlanan keyframe'den **önce** güncel `CODEC_CONFIG`'i yeniden gönderir (varsa). `FRAMES_DROPPED` isteğinde config gönderilmez (çözücü yeniden başlamadı; akış ortasında gereksiz config yok).
- [ ] Sıra garantisi: tüketici config'i o istekten doğan keyframe'den önce görür. Arada eski delta kareler gidebilir (istemci keyframe beklerken onları zaten atıyor), ama config ile keyframe arasına **başka bir keyframe'in config'siz düşmesi** sorun değildir; config yine de ondan önce kuyruktadır.
- [ ] Sınırlı kuyruk kuralları bozulmaz: `CODEC_CONFIG` korunur (atılmaz), kuyrukta birden fazla config birikmez (eskisi yenisiyle değiştirilir ya da birleştirilir), `awaitingKeyframe` mantığı aynı kalır.
- [ ] Parametre setleri henüz yoksa (ilk kare kodlanmadı) davranış bugünkü gibidir.
- [ ] Saf çekirdek testleri (`MateBridgeCore/Video`): STARTUP isteği → kuyrukta `[config, …, keyframe]`; art arda iki istek tek config bırakır; FRAMES_DROPPED config eklemez; dolu kuyrukta config atılmaz. `HEVCEncoder`/`VideoPipeline` tarafı derlenir ve mevcut testler geçer.
- [ ] Log: config yeniden gönderildiğinde `net`/`video` bileşeninde tek satır (`ev=codec_config_resent reason=<n>`), `docs/LOGGING.md` biçiminde.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- İstemcideki sıralama (tablet `STREAM_CONFIG`'i video bağlantısını açmadan önce uygulamalı; PROTOCOL §3 adım 5): ayrı kart gerekirse orkestratör açar. Bu kart tek başına siyah ekranı gidermeli.
- Tel biçimi değişmez. PROTOCOL.md notunu orkestratör yazdı.
- Cihaz testi orkestratörde: `am force-stop` + 2 sn + `am start` beş kez; her seferinde `output_format` ve `dec>0`.

## Plan

1. `MateBridgeCore/Video`: `KeyframeReason.resendsCodecConfig` (STARTUP, DECODE_ERROR, bilinmeyen: true; FRAMES_DROPPED: false).
2. `BoundedFrameQueue.resync(config:)`: kuyruğu boşaltıp yalnızca `[config]` bırakır ve `awaitingKeyframe = true` yapar (yeni tüketici mantığıyla aynı). Böylece config, o istekten doğan keyframe'den önce kuyrukta durur; araya gelen eski delta kareler reddedilir, config atılmaz, birikmez (kuyruk her seferinde sıfırlanır). Ek olarak `push`, kuyrukta zaten aynı içerikte bir `CODEC_CONFIG` varsa ikincisini yutar (kodlayıcı ile yeniden gönderim çakışırsa çift config birikmez).
3. `VideoFrameQueue.resync(config:)`: aynı işlem kilit altında; bekleyen tüketici varsa config'i hemen ona verir (bir sonraki push'u beklemez).
4. `VideoPipeline.requestKeyframe(reason:) -> Bool`: sebep config gerektiriyor ve kodlayıcıda parametre seti varsa önce `frames.resync(config:)`, SONRA `encoder.requestKeyframe(resubmitNow: true)`. Sıra garantisi bu happens-before ile sağlanır: keyframe ancak `forceKeyframe` bayrağı kurulduktan sonra üretilir, bayrak ise kuyruk sıfırlandıktan sonra kurulur; yani o keyframe her zaman config'in arkasından push'lanır. Parametre seti yoksa bugünkü davranış (yalnızca keyframe isteği). Eski parametresiz `requestKeyframe()` (sender'ın reddedilen kare yolu) değişmez.
5. `StreamCoordinator`: `.keyframeRequest(reason)` artık `pipeline.requestKeyframe(reason:)` çağırır; config yeniden gönderildiyse tek satır `ev=codec_config_resent reason=<n>` (component `net`).
6. Testler (`Tests/MateBridgeCoreTests/Video`): STARTUP/DECODE_ERROR/bilinmeyen -> `[config, keyframe]` sırası; FRAMES_DROPPED sebebi config gerektirmez; art arda iki resync tek config; dolu kuyrukta config atılmaz; aynı config'in çift push'u tek kalır; async kuyrukta bekleyen tüketiciye config hemen teslim edilir.

## Handoff

- **Commit:** b403cfe (dal `task/T-030-host-config-with-startup-keyframe`; plan commit'i fabe2c9; kart durumu sonraki commit'te)
- **Dokunulan dosyalar:** `MateBridgeCore/Video/KeyframeResync.swift` (yeni: `KeyframeReason.resendsCodecConfig`), `BoundedFrameQueue.swift` (`resync(config:)`, aynı config'in çift push'unu yutma), `VideoFrameQueue.swift` (`resync(config:)`, bekleyen tüketiciye anında teslim), `MateBridgeHost/Video/VideoPipeline.swift` (`requestKeyframe(reason:)`), `Session/StreamCoordinator.swift` (sebebi iletir, `ev=codec_config_resent reason=<n>` loglar, component `net`), `Tests/MateBridgeCoreTests/Video/KeyframeResyncTests.swift`.
- **Sıra garantisi:** `VideoPipeline.requestKeyframe(reason:)` önce `frames.resync(config:)` (kuyruk kilit altında sıfırlanır: yalnızca `[config]`, `awaitingKeyframe = true`), sonra `encoder.requestKeyframe(resubmitNow: true)` çağırır. Keyframe ancak `forceKeyframe` bayrağı kurulunca üretilir, bayrak kuyruk sıfırlandıktan sonra kurulur; dolayısıyla o keyframe her zaman config'in arkasından push'lanır. Sıfırlamadan önce kodlanmış eski delta kareler `awaitingKeyframe` ile reddedilir (kabul kriterindeki "arada eski delta gidebilir" ifadesinden daha sıkı: hiç gitmezler). Kuyrukta bekleyen tüketici varsa config hemen ona verilir.
- **Varsayımlar:** Bilinmeyen sebep DECODE_ERROR gibi (config gönderilir). Parametre seti yoksa yalnızca keyframe isteği (eski davranış), log yok. Sender'ın reddedilen-kare yolundaki parametresiz `requestKeyframe()` değişmedi. Aynı içerikli iki `CODEC_CONFIG` kuyrukta tek kalır; farklı içerikli config'ler (kodlayıcı yeniden ayarı) birbirini silmez.
- **Test edilmeyenler / cihazda doğrulanacaklar:** `HEVCEncoder`/`VideoPipeline`/`StreamCoordinator` yalnızca derlendi (donanım gerektirir). `check.sh` geçti. Cihazda: `am force-stop` + 2 sn + `am start` beş kez; her seferinde host log'unda `keyframe_request reason=0` ardından `codec_config_resent reason=0`, tablet log'unda `output_format` ve `dec>0`. Ayrıca yeni ekranda (display_reused değil) regresyon olmadığı ve akış ortasında FRAMES_DROPPED sonrası config gelmediği.
- **Açık sorular:** Yok.
