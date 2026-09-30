---
id: T-030
title: Mac — STARTUP/DECODE_ERROR keyframe isteğinde CODEC_CONFIG'i yeniden gönder (hızlı yeniden bağlanmada siyah ekran)
status: done
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

### İnceleme turu 1 (commit f0b260e)

Kod commit'i: **f0b260e** (ilk uygulama b403cfe'dir). Durum `review`. `check.sh` geçti (ALL OK, uyarısız).

1. **Bulgu 1 gerçekti.** `BoundedMailbox.post` aynı `coalesceKey`'li bekleyen olayı "latest wins" ile eziyordu; tüm keyframe istekleri tek anahtarı (`keyframeKey`) paylaştığından bekleyen STARTUP'ı sonradan gelen FRAMES_DROPPED ezebiliyordu (config yeniden gönderilmez, siyah ekran).
   - Düzeltme: saf kural `KeyframeReason.merged(pending:incoming:)` (`MateBridgeCore/Video/KeyframeResync.swift`): bekleyen istek config gerektiriyor ve gelen gerektirmiyorsa bekleyen kalır, aksi halde sonradan gelen kazanır. `BoundedMailbox.post` isteğe bağlı `merge` kapanışı aldı (varsayılan latest-wins; diğer olaylar değişmedi). `StreamCoordinator.post` her zaman `mergeEvents` geçirir; yalnızca iki `keyframeRequest` birleşirken kural devreye girer.
   - Testler: `merged` tablosu, mailbox'ta STARTUP -> FRAMES_DROPPED ve ters sıra, merge'siz post'un hâlâ latest-wins olduğu.
2. **Bulgu 2: seçilen çözüm, anlık görüntüyü kuyruk kilidi altında almak.** `VideoFrameQueue.resync(config: () -> EncodedVideoFrame?)` ve `startNewConsumer(configProvider:)` sağlayıcıyı kuyruk kilidi tutulurken çağırır; kodlayıcı çıktısı `push` ile aynı kilidi kullandığından, kodlayıcının duyurduğu bir config anlık görüntü ile sıfırlama arasına giremez: ya zaten kuyruktadır (sağlayıcı yeni olanı görür) ya sıfırlamadan sonra kuyruğa girer. `VideoPipeline.requestKeyframe(reason:)` ve `prepareForNewConsumer` bunu kullanır (kilit sırası kuyruk -> kodlayıcı; `HEVCEncoder.handle` kendi kilidini `output` çağrısından önce bırakır, tersi yol yok).
   - Neden bu seçenek: `HEVCEncoder` değişmiyor (donanım gerektiren dosyaya dokunulmadı), yeni kilit ya da durum yok, iki çağrı yeri de kapanıyor, saf çekirdekte test edilebiliyor. "Sonraki keyframe'de yeniden duyur" seçeneği kodlayıcıda bayrak ve yarış yüzeyi eklerdi.
   - Yan etki için ek kural: anlık görüntü A, sıfırlama, sonra B'nin push'u durumunda kuyruk `[A, B]` olur ve 2 kapasitede keyframe'in kendisi atılırdı. `BoundedFrameQueue.push` artık kuyrukta yalnızca config'ler beklerken gelen farklı içerikli config'in eskileri değiştirmesini sağlar (`[B]`); gerçek karelerin arkasındaki config'lere dokunulmaz. Yani "farklı config'ler birbirini silmez" varsayımı yalnızca gerçek kareler kuyruktayken geçerli.
   - Testler: sağlayıcı içinde eşzamanlı config push'u başlatılıp sağlayıcı 150 ms uyutulur (kilitsiz uygulamada B sıfırlamada silinirdi); sonuç `[B, keyframe]`. Ayrıca sağlayıcı nil dönerse kuyruk dokunulmadan kalır, `[config A] + push(B) + keyframe` durumunda keyframe yerini korur.
3. **Hâlâ test edilmeyen:** kodlayıcı-kuyruk kilit etkileşimi gerçek `HEVCEncoder` ile (yalnızca derlendi); iki ardışık isteğin (STARTUP + FRAMES_DROPPED) cihazda tek `codec_config_resent reason=0` bırakması; yukarıdaki cihaz senaryoları.

### Cihaz doğrulaması (orkestratör, 2026-09-30 18:35)

Yeni host paketiyle `am force-stop` + 2 sn + `am start` beş kez: 5/5 `display_reused` → `keyframe_request reason=0` → `codec_config_resent reason=0`; tablette her seferinde `output_format` ve durağan ekranda `recv=2 dec=1 shown=1`. Yeni ekranda (ilk bağlantı) regresyon yok. Akış ortasında FRAMES_DROPPED sonrası config gelmediği ve STARTUP+FRAMES_DROPPED birleşmesi canlı oturumda izlenecek (T-025).
