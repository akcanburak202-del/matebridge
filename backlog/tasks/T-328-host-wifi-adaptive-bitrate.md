---
id: T-328
title: Host — tıkanıklık denetleyicisini video kapısına ve kodlayıcıya bağla (Wi-Fi, anahtar) + canlı bit hızı ayarlayıcısını geri getir
status: done
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
  - host-mac/Sources/MateBridgeCore/Session/CongestionController.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/CongestionControllerTests.swift
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

- **Commit:** kod `395d85ce`, test düzeltmesi `80b6d88f` (dal `task/T-328-host-wifi-adaptive-bitrate`; plan `f1a2fe9b`, Handoff ayrı commit). `./scripts/check.sh` -> ALL OK (host swift test 678 XCTest + 1105 swift-testing, gradle, fixtures, crypto, measurement kit).
- **Dokunulan dosyalar:**
  - Yeni: `MateBridgeCore/Session/WifiAdaptation.swift`, `MateBridgeHost/Video/WifiAdaptationDriver.swift`, `Tests/.../Session/WifiAdaptationTests.swift`, `Tests/.../Video/LiveBitrateTests.swift` (T-177'den geri, bilgi bölümü kırpıldı).
  - Değişen: `TransportKnobs.swift` (`WifiAdaptKnob`), `Core/Video/SocketVideoTransport.swift` (`setAdmission`, `notifyReady`), `Core/Video/EncoderSubmitOrder.swift` (T-177 ayarlayıcı geri: `1fe10249^` sürümü), `SessionServer.swift` (`VideoLink.attachAdaptation/sendBufferBytes/tcpConnectionInfo`, `frameWritten` kancası, `cancel` -> adaptation.stop), `StreamCoordinator.swift` (sürücü başlat/durdur), `HEVCEncoder.swift` (`setTargetBitrate`, `applyBitrate`, `Backend.setBitrate`, `initialBitrateKbps`), `PackedAuxEncoder.swift` (`setBitrate`), `VideoPipeline.swift` (`setTargetBitrate`), `BsdTcpSocketTests.swift`, `EncoderSubmitOrderTests.swift` (T-177 testleri geri + keyframe'siz test), `docs/LOGGING.md`.
- **Tick ve düşüş kablolaması:**
  - Tick kaynağı: `WifiAdaptationDriver` kendi 100 ms `DispatchSourceTimer`'ı (oturum kuyruğundan ve 1 s `ev=tcp` ölçerinden bağımsız). Her tick'te video soketinden `TCP_CONNECTION_INFO` okur (kendi `TcpInfoMeter`'ı, retx deltası 100 ms pencere), `adaptation.tick(report:, queueDropsTotal: pipeline.frames.droppedCount)` çağırır. Kare yolunda `getsockopt` yok denebilir: kapı için `admit()` gerekirse en çok 2 ms'de bir `tcpi_snd_sbbytes` okur (anahtar kapalıyken sıfır maliyet).
  - Düşüşler: kapının reddi asla `queueDropped` olmaz. `VideoFrameQueue.droppedCount` artışı (gerçek yeni-kare-kazanır düşüşü) tick başına en çok bir `queueDropped` olur, ama o tick'te ya da bir önceki tick'te kapı en az bir kez reddettiyse sayılmaz (kapının yol açtığı taşma, ör. bütçeden büyük keyframe, kendi kendini besleyen iniş olmasın diye). Uzun süren kapı engellemesi denetleyicinin kendi tetikleyicilerine (sbbytes 3x bütçe, srtt +20 ms, retx) kalır.
  - Kapı: yalnız `SocketVideoTransport.canSend` içinde (yazılabilirlik kapısından sonra). `sendFrame` içinde değil: sender'ın zaten aldığı kareyi reddetmek kareyi kaybettirir ve keyframe ister. Reddedilen kabul üç yoldan yeniden denenir: soketin yazılabilirlik olayı (mevcut), her tick (açık reddi varsa sender'ı uyandırır), 4->20 ms geri çekilmeli yeniden deneme zamanlayıcısı (yazılabilirlik olayı bütçe aşımında hiç gelmez, çünkü soket yazılabilir kalır).
  - Kodlayıcı: iniş hemen, çıkış en çok 500 ms'de bir uygulanır (kuantum 250 kbps, saniyede ~12 adım olurdu). Sürücü başlarken ve dururken kodlayıcıyı tavana alır. Paketlenmiş 4:4:4'te yardımcı oturum `AuxBitratePolicy` ile aynı sahip kuyruğunda ayarlanır.
- **Varsayımlar:** kart `files:` listesindeki `MateBridgeHost/Session/SocketVideoTransport.swift` yolu yanlış (gerçek: `MateBridgeCore/Video/`); Core/Video'daki iki dosya, yeni Core/Session dosyası ve `Tests/.../Video/` kart `files:` listesine eklendi. Tavan = `pipeline.settings.bitrateKbps`, fps = `pipeline.settings.fps`; taban T-327 varsayılanı (12 Mbps). Packed 4:4:4'te `BitrateRequest` aralığı (5-150 Mbps) ana oturum içindir; yardımcı oturum `AuxBitratePolicy` tabanı (1 Mbps) ile. T-177 testleri kartın "XCTest" maddesini XCTest ile karşılıyor (EncoderSubmitOrderTests XCTest).
- **Test edilmeyenler / cihazda doğrulanacaklar:**
  - **VideoToolbox `fast` profilinin canlı `AverageBitRate`/`DataRateLimits` değişimini izleyip izlemediği** (T-177 cihaz kontrolü hiç yapılmadı): `video ev=bitrate_set` durumları 0 mı, `sent_kbps`/`net ev=tcp` bayt hızı hedefi izliyor mu. İzlemiyorsa yalnız kapı etkili olur.
  - Kare başına `admit()` `getsockopt` maliyeti (host CPU) ve kapının gereksiz kısması: `admits_blocked`, `blocked_ms`, `queue_drops`, keyframe sayısı (bütçeden büyük keyframe sonrası kapı kapanır; kuyruk taşması keyframe isteği doğurabilir; T-176 birleştirici bunu yumuşatır).
  - Kapalı döngü davranış (hedef iner mi, 5 s sonra tavana döner mi, durağan metin netliği), denetleyici sabitlerinin başka WLAN'da uygunluğu.
  - Hiçbir cihaz testi çalıştırılmadı; çalışan host uygulamasına dokunulmadı.
- **Codex düzeltmeleri (tur 1):**
  - **P1 (taşma/crash):** `admit()` zaman damgasını kilitten önce okuyor; `takeLogWindow()` açık engel başlangıcını ilerletince `now &- since` sarıyor ve `windowBlockedUs +=` trap edebilirdi. Artık her geçen süre `WifiAdaptation.elapsed(now, since:)` ile (since sonra ise 0) hesaplanıyor, birikim tek yerde (`accrueBlockedLocked`, `&+=`), başlangıç geriye gitmiyor; örnek tazeliği kontrolü de aynı yardımcıyı kullanıyor. Test: `testStaleTimestampNeverWrapsTheBlockedAccounting` (eski saat okumasıyla admit/tick/takeLogWindow).
  - **P2 (kalıcı engellemede iniş yok):** kapı reddi sırasındaki kuyruk düşüşlerinin bastırılması kaldı (keyframe taşması iniş doğurmasın), ama sınırlandı: son 20 tick'te (2 s) kapı süresinin >= %60'ı kapalıysa **ve** o aralıkta host kuyruk düşüşü varsa yeni `CongestionController.Trigger.blocked` (`blockedTooLong(nowUs:)`, T-327 dosyasına küçük ek; aynı x0,7 ve en az max(srtt,250 ms) aralığı) hedefi düşürür; kanıt silinir, bir sonraki iniş için yeniden 2 s gerekir. Eşik gerekçesi `WifiAdaptation.sustainedTicks` yorumunda: gözlenen en büyük keyframe'ler 240-680 KB, 12 Mbps tabanda 0,45 s boşalır; 1 MB bile 0,67 s = aralığın %33'ü; %60 = 1,2 s = tabanda 1,8 MB keyframe. Testler: `testOneOversizedKeyframeNeverLowersTheTarget` (1 s engel, düşüş yok), `testSustainedBlockingOnAnUnderCapacityLinkLowersTheTargetOncePerSpan` (2 s aralık başına bir iniş, hedef 60000 -> 29500), `testBlockingWithoutQueueDropsIsNotACongestionSignal`. `ev=adapt_step trigger=blocked` LOGGING.md'de.
- **Codex düzeltmeleri (tur 2):**
  - **Keyframe patlaması send-buffer tetikleyicisinden iniş yaptırıyordu:** ham 100 ms TCP örneği tek başına `.sendBuffer` tetikliyordu (60 Mbps'te 680 KB keyframe > 450 KB). Artık tampon 3 bütçenin üstünde `CongestionController.sendBufferSustainMs` = 400 ms kesintisiz kalmalı (ardışık okumalar; 1 s tick'te ikinci okuma). Gerekçe sabitin yorumunda: 680 KB keyframe 3 bütçenin üstünde 60 Mbps'te 91 ms, 30 Mbps'te 121 ms, en küçük bütçeyle (tabanda 90 KB eşik) 0,39 s < 0,4 s. Testler: `oneKeyframeBurstInTheSendBufferIsNotCongestion`, `sendBufferStreakNeedsConsecutiveReadingsAcrossTheSustainTime`, `sendBufferFarOverBudgetForLongLowersTarget` (controller); `WifiAdaptationTests.testOneOversizedKeyframeNeverLowersTheTarget` artık kabul ve tick okumaları eşleşiyor (680k..0 boşalan tampon), `testSustainedBacklogLowersTheTarget`.
  - **Toparlanma yavaştı (tabandan ~18 s):** denetleyiciye boşta toparlanma eklendi: son tetikleyiciden `quietMs` sonra ve son `demandWindowMs` (1 s) boyunca `frameWritten` ile yazılan hız hedefin `recoveryDemandFraction` (%50) altındaysa hedef doğrudan tavana atlar (talep düşük, tıkayamaz). Yük altında eğim aynı. Talep, kapı o pencerede reddettiyse güvenilmez sayılır (`Tick.gateRefused`, `WifiAdaptation` geçirir): yazılan bayt azlığı durağan ekrandan değil kapıdan olabilir, yoksa kapı ve sıçrama birbirini sarar. Sürücünün 500 ms çıkış sınırı tavan sıçramasını geciktirmez (`WifiAdaptation.shouldApply`: iniş ve tavan hemen). Testler: `staticSceneJumpsToTheCeilingWithinFiveSeconds` (tabana indir, durağan sahne: >= 2 s, <= 5 s), `busySceneKeepsTheSlope`, `demandIsNotTrustedWhileTheGateRefuses`, `aNewTriggerRestartsTheQuietPeriodBeforeTheJump`, `testEncoderApplyPolicyNeverDelaysDecreasesOrTheCeilingJump`.
  - **T-327 replay yeniden kaydedildi:** replay artık saniyedeki tüm kareleri `frameWritten` ile besliyor (eskiden saniyede tek çağrı; istatistik satırı olmayan saniyede önceki satırın hızı sürüyor). 418 saniyeden 36'sında beklenen hedef değişti: 15-35. saniyeler (oyun yüklenirken talep düşük, ilk kesintiden sonra tavana atlıyor, sonra 385 paketlik patlama 42000'e indiriyor; eskiden 15->33 Mbps eğim ve 25250), 69-71 ve 342-345, 351-352, 362-365, 369-370 (kısa toparlanma farkları). Diğer saniyeler ve altın testlerin tümü (düşüş anlarında iniş, son dakikada tavan, tek paketlik retx hafif) aynı kalıyor. Replay açık döngü olduğundan bu sıçramalar kapalı döngüde nasıl davranacak cihazda görülür.
- **Cihaz A/B'de loga bakılacaklar:** `video ev=adapt` (saniyelik: `target_kbps`, `sbbytes_p95`, `srtt_ms`, `admits_blocked`, `blocked_ms`, `queue_drops`, `down_steps`), `video ev=adapt_step` (inişlerde `trigger=`), `video ev=bitrate_set` (`avg_status=0 limits_status=0`, `aux_status`), `net ev=tcp` (video `sndbuf_bytes`, `retx_pkts_delta`, kontrol srtt p95), `video ev=cadence` (`queue_drops`), tablet tarafı fps/ses kesintisi. USB oturumunda hiç `adapt*` satırı çıkmamalı.

## Open questions

- **KNOBS.md satırı (orkestratör ekler):** `MATEBRIDGE_WIFI_ADAPT=1` | varsayılan kapalı | `TransportKnobs.swift` (`WifiAdaptKnob`), `StreamCoordinator.swift` (`onVideoAttached`), `WifiAdaptationDriver.swift` | T-328 | yalnızca geliştirici (A/B sonrası varsayılan kararı) | Wi-Fi'de gönderim kapısı + canlı bit hızı; yalnız `transport=wifi`. KNOBS satır 41 (BITRATE_STEP) kaldırılmış kalır.
- **PROTOCOL §0x03 `bitrate_kbps`** "tavan; host tıkanıklıkta altında kodlayabilir" metni orkestratörün; bayt/fixture değişmedi.
- **`StreamProfileLog.knobAllowList`** (`ev=profile knobs=`) `MATEBRIDGE_WIFI_ADAPT`'i listelemiyor (dosya kart kapsamında değil); A/B'de anahtar açık/kapalı oturumları `ev=adapt_start` varlığından ayırt edilir. İstenirse küçük bir takip kartı.
- **Kapsam sapması:** `files:` listesi güncellendi (yukarıda). Kart yolu `MateBridgeHost/Session/SocketVideoTransport.swift` yanlıştı.
- F A-4 (kontrol H->C trafiği alçak su işaretini yok sayar): düzeltilmedi, kapsam dışı.
- Denetleyici tek-iki paket retx'te (< 4/pencere) yalnız x0,9 uyguluyor; 100 ms tick'te bir olay iki tick'e bölünürse "hafif" sayılabilir (kalibrasyon 1 s tick'ti). Cihazda `down_steps` ve `trigger=retransmit` sıklığına bakılmalı; gerekirse sürücü retx'i 1 s kayan pencerede toplayacak şekilde değiştirilir.
