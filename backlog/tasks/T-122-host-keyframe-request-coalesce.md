---
id: T-122
title: Host — art arda gelen KEYFRAME_REQUEST'leri birleştir (bir IDR yoldayken yenisini zorlama); IDR boyutunu logla
status: blocked
phase: 5
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-122-host-keyframe-request-coalesce.md
---

## Amaç

Cihaz (2026-10-02 ~11:00), T-121 ile aynı olay. Ses kesintilerinden önce host 100–300 ms içinde 4–6 `keyframe_request` alıyor (`reason=2`, arada `reason=0` + `codec_config_resent`) ve her birinde `requestKeyframe(resubmitNow: true)` çağırıyor. Sonuç: birden çok büyük IDR. O saniye `sent_kbps` 38 879 oldu (normalde 2–5 Mbps). Bağlantı doluyor ve ses 30–250 ms gecikiyor.

Bir IDR zaten kodlanmış ya da gönderilmekteyken gelen yeni istek, istemcinin henüz o IDR'yi görmemesinden kaynaklanır. Yeni bir IDR bunu çözmez, yükü katlar.

## Kapsam dışı

- Tablet tarafı kuyruk/istek politikası (T-121, paralel).
- IDR boyutunu düşürmek (QP/oran sınırı, intra refresh): ayrı karar. Bu kart yalnız ölçer.
- Protokol değişikliği.

## Kabul kriterleri

- [ ] **Birleştirme:** bir istekle zorlanan IDR'nin kodlanması ve sokete yazılması bitene kadar, ve yazımdan sonra kısa bir pencere boyunca (RTT + istemcinin çözme süresi; varsayılan 250 ms, Plan'da gerekçe) gelen `FRAMES_DROPPED` istekleri yeni IDR zorlamaz; yalnız sayılır.
  - `STARTUP` / `DECODE_ERROR` codec config gerektirdiği için config yeniden gönderilir.
  - Hemen önce gönderilmiş bir IDR varsa ikinci IDR zorlanmaz. Config + mevcut IDR'nin yeniden gönderilmesinin mümkün olup olmadığı Plan'da değerlendirilir.
  - Kural: istemci bir keyframe'i en geç pencere sonunda görür; birleştirme bir isteği asla sonsuza kadar yutmaz.
- [ ] Log: `ev=keyframe_request reason= action=forced|coalesced|config_resent since_idr_ms=`. Saniyelik `net ev=stats` satırına `idr=` (gönderilen IDR sayısı) ve `idr_bytes_max=` eklenir.
- [ ] `docs/LOGGING.md` güncellenir.
- [ ] Birleştirme mantığı Core'da, birim testli (sahte saat): tek istek → IDR; 4 istek / 200 ms → 1 IDR; pencere sonrası istek → yeni IDR; STARTUP → config yeniden gönderimi.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde.

## Plan

**Core: `KeyframeRequestCoalescer`** (`MateBridgeCore/Video/KeyframeRequestCoalescer.swift`, saf struct, saat dışarıdan µs):
- Durum: `pending` (zorlanmış ama henüz sokete yazılmamış IDR: zorlama anı + o andaki "kuyruğa itilen keyframe sayısı"), `lastWrittenUs` (yazımı biten son keyframe), pencere sayaçları (`idr`, `idr_bytes_max`), `coalesced` toplamı.
- `FRAMES_DROPPED`: `pending` yaşı < `pendingTimeoutUs` (1 s) ya da son yazım < `windowUs` (250 ms) önce ise → `coalesced` (yalnız sayılır). Değilse → `forced` (+ `pending`).
- `STARTUP` / `DECODE_ERROR`: config her zaman yeniden gönderilir (`action=config_resent`). IDR yalnız zorlanmış IDR hâlâ **kodlayıcıdaysa** (kuyruğa itilmemiş) zorlanmaz: o IDR resync'ten sonra, config'in arkasından gelir. Bu, kuyruk kilidi altında resync ile aynı anda okunan `keyframesPushed` sayacının zorlama anındaki değere eşit olmasıyla anlaşılır (yarış güvenli: yanılgı yalnız fazladan IDR yönünde). Kuyruktaki IDR resync ile atılır; yazılmakta/yazılmış IDR config'ten önce gider → yeni IDR zorlanır.
- `keyframeWritten(nowUs, bytes)`: herhangi bir keyframe'in yazımı bitti → `pending` temizlenir, `lastWrittenUs`, pencere sayaçları.
- `internalForce` (kuyruk taşması, gönderici reddi, yeni tüketici): her zaman zorlar ama `pending` olarak işaretler, böylece istemcinin arkadan gelen FRAMES_DROPPED'ı birleşir.
- Kural "asla sonsuza kadar yutma": birleşen her istek ya yoldaki bir IDR ile (en geç `pendingTimeoutUs` içinde, sonra bir sonraki istek yeniden zorlar) ya da son `windowUs` içinde yazılmış bir IDR ile karşılanır. Kodlayıcı zorlama bayrağı bir kare gönderilene kadar kalır, başarısız kodlamada yeniden kurulur.

**250 ms penceresi:** yazım bitişi = çekirdeğe verildi. İstemcinin IDR'yi alması için RTT (USB ~1 ms, Wi-Fi 5–40 ms, sıçramalarla daha fazla) + soket tamponunda kalan bayt (yüzlerce KB'lık IDR, Wi-Fi'de ~100 ms) + IDR çözme (2800×1840, ~15–30 ms) + istemci kuyruğu gerekir. Cihazda fırtına 100–300 ms içinde 4–6 istek; 250 ms bunun çoğunu kapsar, daha uzun pencere gerçekten kaybolmuş bir IDR'nin telafisini geciktirir. T-121 istemci tarafında 500 ms istek sınırı koyuyor; pencere bundan kısa, yani istemcinin sınır sonrası tekrar isteği yeni IDR alır.

**Config + mevcut IDR'nin yeniden gönderilmesi (değerlendirme):** yazılmış bir IDR'nin baytlarını saklayıp config'in arkasından tekrar göndermek yalnız o IDR'den sonra hiç delta kodlanmadıysa geçerli (sonraki deltalar IDR sonrası kareleri referans alır). 60–120 fps'te bu ~8–16 ms'lik bir aralık; pratikte işe yaramaz ve bozuk görüntü riski taşır → yapılmıyor. Kuyrukta bekleyen IDR'yi resync'te tutmak (config'i öne koyarak) mümkün ama 2 karelik kuyruk sınırıyla etkileşiyor (config + IDR + delta = 3; sonraki itme deltayı atar ve yine istek doğurur) → bu kartta yapılmıyor; Açık sorular'a not.

**Host (`VideoPipeline`):** kilitli bir `KeyframeGate` kutusu birleştiriciyi tutar. `handleKeyframeRequest(reason:) -> KeyframeRequestDecision` (log alanları dahil); `requestKeyframe(reason:) -> Bool` geriye uyumlu sarmalayıcı. `recordTrace` keyframe yazımlarını birleştiriciye bildirir (`FrameTrace`'e `isKeyframe`, `bytes` eklenir; `VideoSender` doldurur). `takeKeyframeWindow()` → `idr= idr_bytes_max=`. `VideoFrameQueue`'ya kilit altında `keyframesPushed` sayacı ve sayacı döndüren resync eklenir.

**Log:** `ev=keyframe_request reason= action=forced|coalesced|config_resent idr_forced=0|1 since_idr_ms=<n>|-`; `net ev=stats` sonuna `idr= idr_bytes_max=`. Bu iki satır `StreamCoordinator.swift`'te üretiliyor (Açık sorular).

**Testler (sahte saat):** tek istek → IDR; 4 istek / 200 ms → 1 IDR; pencere sonrası → yeni IDR; pending zaman aşımı → yeni IDR; STARTUP → config + (IDR kodlayıcıdaysa zorlama yok, kuyruğa itilmişse zorla); yazım pencere sayaçları; `VideoFrameQueue.keyframesPushed`.

## Handoff

- **Commit:** `aca06d3` (uygulama); plan `08bd8d4`, `672f250`. Branch `task/T-122-host-keyframe-request-coalesce`.
- **Dokunulan dosyalar:**
  - `host-mac/Sources/MateBridgeCore/Video/KeyframeRequestCoalescer.swift` (yeni): birleştirme kuralları + IDR pencere sayaçları.
  - `host-mac/Sources/MateBridgeCore/Video/VideoFrameQueue.swift`: kilit altında `keyframesPushed` sayacı, `resyncCountingKeyframes(config:)` (eski `resync(config:) -> Bool` buna sarmalayıcı).
  - `host-mac/Sources/MateBridgeCore/Video/LatencyTrace.swift`: `FrameTrace.isKeyframe`, `FrameTrace.bytes`.
  - `host-mac/Sources/MateBridgeCore/Video/VideoSender.swift`: bu iki alanı yazım başında doldurur.
  - `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`:
    - `handleKeyframeRequest(reason:) -> Decision`; `requestKeyframe(reason:) -> Bool` artık birleştiriciden geçer.
    - `requestKeyframe()`, kuyruk taşması ve `prepareForNewConsumer` iç zorlama olarak kaydedilir.
    - `recordTrace` keyframe yazımlarını bildirir; `takeKeyframeWindow()` eklendi.
  - `host-mac/Tests/MateBridgeCoreTests/Video/KeyframeRequestCoalescerTests.swift` (yeni, 15 test), `IntegrationTests.swift` (trace alanları).
  - `docs/LOGGING.md`.
- **Varsayımlar:**
  - Pencere 250 ms, pending zaman aşımı 1 s (gerekçe Plan'da).
  - "Yazıldı" = gönderici trace tamamlanması (transport yazımı işledi, yani çekirdeğe verildi). İstemcinin aldığı an değil.
  - `StreamCoordinator` her zaman `trace` kapanışı veriyor. Vermezse yazımlar görülmez; birleştirme yalnız pending zaman aşımıyla çalışır.
  - STARTUP/DECODE_ERROR: yazılmış ya da kuyruktaki IDR yeniden kullanılmaz. Yalnız hâlâ kodlayıcıdaki IDR kullanılır (gerekçe Plan'da).
- **Davranış şimdiden etkin:** mevcut `StreamCoordinator` `requestKeyframe(reason:)` çağırıyor, o da birleştiriciden geçiyor. Eksik olan yalnız log biçimi (aşağıda).
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - Fırtına anında host logunda istek başına `action=coalesced`. Saniyede `idr` 1 (en çok 2) olmalı; `sent_kbps` sıçraması ve ses gecikmesi kaybolmalı.
  - Mid-stream STARTUP sonrası görüntü bozulmadan devam etmeli (config + IDR sırası). Özellikle `idr_forced=0` yolu: IDR kodlayıcıdayken gelen STARTUP.
  - Yeni bağlantıda (ilk STARTUP) tek IDR gitmeli (`prepareForNewConsumer` IDR'si kodlayıcıdaysa ikinci zorlanmaz).
  - Wi-Fi'de büyük IDR yazımı > 1 s sürerse pending zaman aşımı sonrası bir istek yeniden zorlar. Beklenen, nadir.
- **Açık sorular:**
  1. **Kapsam (engelleyici):** kabul kriterindeki iki log satırı (`ev=keyframe_request … action=` ve `net ev=stats … idr= idr_bytes_max=`) `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`'te üretiliyor. Bu dosya `files:` listesinde yok; listedeki `SessionServer.swift`'te ilgili kod yok. Dosyaya dokunmadım. Önerilen yama (derlendi, uygulanmadı):
     ```swift
     // handle(.keyframeRequest): eski iki log satırı yerine
     if let decision = pipeline?.handleKeyframeRequest(reason: reason) {
         log(.info, "keyframe_request", "reason=\(reason.rawValue) \(decision.logFields)")
     } else {
         log(.info, "keyframe_request", "reason=\(reason.rawValue) action=no_pipeline")
     }
     // onStats: log(.info, "stats", fields) satırından hemen önce
     if let pipeline { fields += " " + pipeline.takeKeyframeWindow().logFields }
     ```
     `docs/LOGGING.md` bu yamadan sonraki biçimi anlatıyor. Onay gelirse uygularım.
  2. Kuyruktaki IDR'yi resync'te tutmak (config öne, IDR + arkası korunur) bir IDR daha kazandırır. Ancak 2 karelik sınırla etkileşiyor (config + IDR + delta = 3 → sonraki itmede delta atılır, iç istek doğar). Config'in kapasiteye sayılmaması gibi ayrı bir karar gerekir.
