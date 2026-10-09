---
id: T-328
title: Host — tıkanıklık denetleyicisini video kapısına ve kodlayıcıya bağla (Wi-Fi, anahtar) + canlı bit hızı ayarlayıcısını geri getir
status: todo
phase: 7
owner: mac-host-dev
depends_on: [T-327, T-326]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/TransportKnobs.swift
  - host-mac/Sources/MateBridgeHost/Session/SocketVideoTransport.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/MateBridgeCoreTests/Session/
  - host-mac/Sources/MateBridgeCore/Video/SocketVideoTransport.swift
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Sources/MateBridgeCore/Session/WifiAdaptation.swift
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - docs/LOGGING.md
  - backlog/tasks/T-328-host-wifi-adaptive-bitrate.md
---

## Amaç

**T-196**'nın yeniden açılışı (0023 eki 2026-10-09). T-327 denetleyicisini video gönderim kapısına ve kodlayıcıya bağla; yalnız `transport == .network` ve anahtar açıkken. Canlı bit hızı ayarlayıcısı (T-177) 2026-10-08'de T-302 ile silindi; git geçmişinden geri getir (T-177 commitleri `6594e1a4`, `893b34c4`; silme `1fe10249`) ve denetleyicinin hedefini yeniden başlatmasız, keyframe'siz uygula.

## Bağlam

- **Tasarım:** `backlog/tasks/T-196-host-wifi-adaptive-send.md` *Bağlam*, *Kapsam dışı* ve *Kabul kriterleri* aynen geçerli (anahtar `MATEBRIDGE_WIFI_ADAPT=1` varsayılan kapalı; kapalıyken kapı davranışı birebir bugünkü; engellenen kabul yazılabilir **ve** tick'te yeniden denenir; `video ev=adapt` saniyelik log; USB'de hiç devreye girmez). Satır numaraları eski; HEAD'de yeniden doğrula. T-186/T-187/T-189 serileştirme notları artık geçersiz (birleşti).
- T-326 aynı dosyalara (`TransportKnobs.swift`, `SessionServer.swift`) dokunuyor: T-326 birleştikten sonra başla.
- T-302 sonrası `KNOBS.md` satırı 41-42 (canlı bit hızı) kaldırıldı olarak işaretli; yeni anahtar satırını Açık sorular'a yaz, orkestratör ekler.
- PROTOCOL §0x03 `bitrate_kbps` metni (tavan) orkestratörün işi; bayt/fixture değişmez.
- **Cihaz prosedürü (orkestratör):** Wi-Fi, Oyun 60 Mbps, sabit hareket sahnesi + ses, anahtar açık/kapalı iç içe ≥ 3 tur × 3 dk. Ölçüt: `queue_drops`, kontrol srtt p95, ses kesintisi, client fps, durağan metin netliği (5 s sonra tavana dönüş).

## Kapsam dışı

- T-196 *Kapsam dışı* ile aynı. Varsayılanı açmak (A/B sonrası orkestratör).

## Kabul kriterleri

- [ ] T-196 *Kabul kriterleri*'nin tamamı (cihaz maddeleri orkestratörün).
- [ ] [XCTest] Canlı ayarlayıcı: hedef değişimi kodlayıcı sahibinin kuyruğundan geçer, birikenler birleştirilir (T-177 davranışı), boru hattı yeniden başlamaz, keyframe istenmez.
- [ ] Codex incelemesi (taşıma değişikliği) çalıştırıldı, bulgular çözüldü (orkestratör).
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. **Kapsam notu.** Kartın `files:` listesi `MateBridgeHost/Session/SocketVideoTransport.swift` diyor; dosya gerçekte `MateBridgeCore/Video/SocketVideoTransport.swift` (T-196'daki yol doğruydu). Canlı ayarlayıcı da `MateBridgeCore/Video/EncoderSubmitOrder.swift` içinde yaşıyordu. Bu iki Core dosyası, yeni `MateBridgeCore/Session/WifiAdaptation.swift` ve ilgili test dosyaları `files:` listesine eklendi (açık sorulara da yazıldı); başka dosyaya dokunulmaz.
2. **Anahtar.** `WifiAdaptKnob` (`TransportKnobs.swift`): `MATEBRIDGE_WIFI_ADAPT` yalnız `1` açar, yok/geçersiz kapalı. `isActive(env, transport)` = anahtar açık **ve** `transport == .network`; kapı ve sürücü yalnız buna bakar, USB'de hiçbir şey kurulmaz (denetleyici hiç yaratılmaz).
3. **`WifiAdaptation` (Core, saf mantık + enjekte edilen okuyucular).** `CongestionController`'ı kilit altında sarar. Enjekte: `readSendBuffer: () -> UInt32?` (video soketinin `tcpi_snd_sbbytes` değeri), `nowUs`, `schedule(afterUs, fire)`, `wake`. API: `admit()` (kapı), `frameWritten(bytes:)`, `tick(report:, queueDropsTotal:)`, `stop()`, saniyelik `takeLogWindow()`.
   - `admit()`: soket tamponunu okur (en çok 2 ms'de bir `getsockopt`; `canSend` + `sendFrame` çifti tek okumayı paylaşır; okuma başarısızsa **kabul**: kapı kendiliğinden kilitlenmez). `controller.mayWrite` false ise ret + `admitsBlocked += 1` + yeniden deneme zamanlayıcısı kurulur (4 ms, her turda iki katına, tavan 20 ms). Zamanlayıcı yeniden örnekler; kabul oluyorsa `wake()` çağırır (taşıyıcının hazır işleyicisi). Böylece engellenen kabul hem yazılabilirlik olayında (mevcut yol) hem tick'te hem bu hızlı yeniden denemede yeniden denenir; uyanış kaybolamaz. `wake()` hiçbir kilit tutulurken çağrılmaz.
   - **Tick kaynağı:** `getsockopt` kare yolundan çıkmıyor (kapı için taze sbbytes şart; bütçe ~20 ms veri, 100 ms eski değer yanlış reddeder) ama yalnız anahtar açıkken ve ≥ 2 ms aralıkla, kapalıyken sıfır maliyet. Denetleyici tick'i ise 100 ms: Host'ta `WifiAdaptationDriver` kendi `DispatchSourceTimer`'ı ile (100 ms) `connectionInfo()` okur, kendi `TcpInfoMeter`'ı ile retx deltasını (100 ms pencere) çıkarır ve `adaptation.tick`'e verir. `ev=tcp` 1 s ölçerinden bağımsızdır (onun tabanını oynatmaz). 1 s yerine 100 ms çünkü hızlı-in 1 s gecikmeyle 60 Mbps'te ~7 MB kuyruk biriktirir; denetleyici zaten 100 ms tick'e göre tasarlandı (en çok max(srtt, 250 ms)'te bir iniş).
   - **`queueDropped` kuralı:** kapının kendi reddi **asla** raporlanmaz. Gerçek yeni-kare-kazanır düşüşleri (`VideoFrameQueue.droppedCount` artışı = `queue_drops`) tick başına en çok bir `queueDropped` olur, **ama** o tick'te ya da bir önceki tick'te kapı en az bir kez ret verdiyse sayılmaz (`gateRefusedRecently`): kapı engellemesinin yol açtığı kuyruk taşması (ör. büyük keyframe sonrası) kendi kendini besleyen bir iniş döngüsü olur. Kapı engellemesi sürerse zaten `sendBuffer`/`queueDelay`/retx tetikleyicileri denetleyicide. Kuyruk düşüşü tick'ten gelir (`droppedCount` farkı), `keyframeNeeded` geri çağrısına bağlanmayız.
4. **`SocketVideoTransport`.** `setAdmission(_ admit: (@Sendable () -> Bool)?)` + `notifyReady()`. `canSend` ve `sendFrame`, mevcut kapıdan (inFlight, yazılabilirlik) sonra admission'a bakar; reddedilen kare mühürlenmez (sayaç harcanmaz). Admission `nil` (varsayılan) iken kod yolu bugünküyle birebir. Kilit sırası: taşıyıcı -> adaptation -> bağlantı.
5. **`VideoLink`** (`SessionServer.swift`): `attachAdaptation(_:)` kapıyı bağlar; `send` tamamlanmasında başarılıysa `frameWritten(bytes: frame.data.count)`; `readTcpInfo()` sürücü için. Bağlantı kapanınca `adaptation.stop()`.
6. **Canlı ayarlayıcı geri gelir** (`6594e1a4` + `893b34c4`, `1fe10249`'un silişi geri): `CompressionBackend.setBitrate`, `BitrateRequest`, `EncoderSubmitOrder.setBitrate` (sahip kuyruğundan, birleştirmeli, `currentBitrateKbps`), `HEVCEncoder.setTargetBitrate/applyBitrate` (`AverageBitRate` + `DataRateLimits`; **keyframe istenmez, boru hattı yeniden başlamaz**). `MATEBRIDGE_BITRATE_STEP` zamanlayıcısı geri **getirilmez**. Packed 4:4:4'te yardımcı oturum da `AuxBitratePolicy.kbps(main:)` ile aynı sahip kuyruğunda ayarlanır. `VideoPipeline.setTargetBitrate(kbps:)` + `droppedFrameCount` okuyucusu.
7. **`WifiAdaptationDriver` + `StreamCoordinator`.** `onVideoAttached` içinde anahtar+`.network` ise sürücü başlar (tavan = `pipeline.settings.bitrateKbps`, taban 12 Mbps), kodlayıcıyı tavana alır (önceki bağlantıdan düşük kalmış olabilir); `stopConsumer`/`onSenderEnded` içinde durur ve kodlayıcıyı tavana geri alır. `video ev=adapt` saniyede bir: `target_kbps sbbytes_p95 srtt_ms admits_blocked` + `trigger`, `budget_bytes`, `queue_drops`, `retx_pkts`. Hedef değişince `video ev=adapt_step` (eski-yeni, tetikleyici). Yalnız sayılar.
8. **Testler.** (a) Core: `WifiAdaptKnobTests` (yok/geçersiz kapalı; USB'de aktif değil), `WifiAdaptationTests` (sahte okuyucu/zamanlayıcı: bütçe üstü ret + yeniden deneme uyanışı + yazılabilirlik/tick yolunda kayıp uyanış yok; okuma hatasında kabul; kapı reddi `queueDropped` olmaz; kapı reddi olmayan düşüş `queueDropped` olur; stop zamanlayıcıyı iptal eder), `SocketVideoTransport` admission (loopback çifti: nil admission = bugünkü kabul/ret dizisi birebir, reddedilen karede sealer sayacı harcanmaz), (b) `LiveBitrateTests` + `EncoderSubmitOrderTests` bit hızı kısımları (T-177'den geri): hedef değişimi sahip kuyruğundan geçer, birikenler birleşir, keyframe istenmez, stop sonrası dokunulmaz.
9. **Belgeler.** `docs/LOGGING.md`: `video ev=adapt` / `ev=adapt_step`. KNOBS satırı Açık sorulara (orkestratör ekler). A-4 notu (H→C kontrol alçak-su-işaretini yok sayar) bu kartta düzeltilmez.
Riskler: (1) VideoToolbox `fast` profilinde `AverageBitRate` canlı değişimi izlemeyebilir (T-177 cihaz kontrolü hiç yapılmadı): `ev=adapt` + cihaz A/B'de `sent_kbps` ile doğrulanır; izlemezse yalnız kapı etkili olur. (2) Kare başına `getsockopt` (anahtar açıkken, ≤ 1 / 2 ms): ölçülmedi, cihaz A/B'de `host cpu` bakılacak. (3) Denetleyici sabitleri tek oturumdan kalibre.


## Handoff

_(Ajan bitirince doldurur.)_

## Open questions
