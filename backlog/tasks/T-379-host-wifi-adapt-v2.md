---
id: T-379
title: Host — WIFI_ADAPT v2: yalnız bit hızı, doğrulanmış tıkanıklık kanıtı, IDR'sız (astra öneri 1)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-378]
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Session/SessionServer.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - tools/measure/
  - backlog/tasks/T-379-host-wifi-adapt-v2.md
---

## Amaç

`docs/reviews/2026-10-25/astra-wifi-game.md` öneri 1. Kontrol yasası: **0023 eki 2026-10-25** (sinyaller S/D/L/B, ağır/orta yanıt, taban 30 / acil 20, +2 Mbps/sn). Sabitler oradan alınır; ekten sapma gerekirse Open questions'a yazılır, kendiliğinden değiştirilmez.

## Kabul

1. `MATEBRIDGE_WIFI_ADAPT=1` v2 denetleyicisini kurar; v1 denetleyicisi ve ek gönderim kapısı (uçuştaki bayt bütçesi) kaldırılır. Anahtar kapalıyken davranış bugünküyle bayt bayt aynı (mevcut testler yeşil).
2. Açıkken değişen tek şey canlı kodlayıcı bit hızı: akış yeniden başlamaz, IDR istenmez, `config_id` değişmez, gönderim kapısı/kuyruk sınırları bit hızına bağlanmaz.
3. Saf (Pure Swift, zaman enjekte) denetleyici 0023 ekindeki yasayı uygular; S sinyali gönderici tarafından (yazım/kuyruk başı yaşı ve bayt ilerlemesi) beslenir, ilerleyen büyük keyframe yazımı stall sayılmaz.
4. İz tekrarları (`CongestionReplayTrace` örneği gibi, sayısal özet; ham log commitlenmez):
   - 2026-10-25 20:55:36–41 takılması: ikinci stall'dan sonra ≤ 1 sn içinde ×0,7 düşüş; olay sırasında tabanın altına inmez; temizlikten sonra tavana +2 Mbps/sn döner.
   - 2026-10-25 14:25–15:11 temiz oturum: düşüş ≤ 1/10 dk, tabana hiç inmez.
   - v1 çöküş biçimi (tek srtt sıçraması, tekrar eden srtt fazlası birikimsiz): düşüş yok.
5. Birim testleri: taze kanıt kuralı, en sık adım aralıkları, acil tabanın yalnız 30'da 2 sn ağır kanıttan sonra devreye girmesi, tavan değişimi (kullanıcı bit hızını düşürürse anında uyulur), bağlantı değişiminde taban sıfırlama, USB'de hiç kurulmaması.
6. Kayıt: `video ev=adapt` + saniyelik durum alanları `docs/LOGGING.md`'de; `docs/KNOBS.md` satır 48 v2'yi anlatır.
7. Cihaz (orkestratör, sonra): Oyun 60, anahtar açık; `sent_kbps` `bitrate_set`'i izliyor, takılma anında düşüş, temizlikte geri dönüş. Varsayılan açma ayrı ek ile.

## Plan

1. **Saf denetleyici** `MateBridgeCore/Session/WifiAdaptV2.swift`: `WifiAdaptV2Controller` (zaman enjekte, I/O yok). Girdi her 100 ms: srtt, sndbuf, tx/retx paket deltası, S durumu. Sabitler tek enum'da (`WifiAdaptV2.Constants`), değerler 0023 ekinden. D tabanı `RttBaseline` (30 sn, yalnız boşalmış örnekler, düşük yüzdelik). Ağır ×0,7 / 500 ms, orta ×0,85 / 750 ms, taze kanıt (adımdan sonra halkalar ve S olayları temizlenir), tek başına S/D/L yalnız 2 sn yukarı bekletmesi, taban 30, acil 20 (30'da, girişten >= 2 sn sonra ağır kanıt), 3 temiz sn sonra +2 Mbps/sn, `setCeiling`, `connectionChanged`.
2. **S ölçümü (gönderici tarafı)**: saf `SendStallDetector` (Core/Video). `SocketVideoTransport` uçuştaki kaydın başlangıcını ve kernel'e verilen kümülatif baytı tutar (`stallObservation`); kuyruk başı yaşı `VideoFrameQueue.headEnqueuedUs`. Detector: bekleyen iş (yazım ya da kuyruk başı) >= 150 ms ve bu sürede bayt ilerlemesi yok -> stall olayı; ilerleyen büyük keyframe yazımı sayılmaz (ilerleme = stall değil).
3. **Sürücü**: `WifiAdaptationDriver` yeniden yazılır (100 ms zamanlayıcı, TCP bilgisi + stall örneği -> denetleyici -> `pipeline.setTargetBitrate`), `video ev=adapt` değişim satırı + saniyelik durum. v1 (`CongestionController`, `WifiAdaptation`) ve gönderim kapısı (`setAdmission`, `attachAdaptation`) silinir.
4. **Testler**: denetleyici birim testleri (taze kanıt, aralıklar, acil taban, tavan, bağlantı değişimi, USB knob), detector testleri, iz tekrarları (`WifiAdaptV2Traces`: saniyelik sayısal özet, ham log yok; 1 sn -> 100 ms eşlemesi dosya başlığında belgeli): 20:55 takılması, 14:25-15:11 temiz oturum, v1 çöküş biçimi.
5. **Belgeler**: LOGGING.md `ev=adapt`, KNOBS.md satır 48.

## Handoff

- **Commit**: f19a9b1b (başlık; tam test: 760 test, 0 hata) (dal `task/T-379-host-wifi-adapt-v2`).
- **Dosyalar**: yeni `MateBridgeCore/Session/WifiAdaptV2.swift` (saf `WifiAdaptV2Controller` + `RttBaseline`), `MateBridgeCore/Video/SendStallDetector.swift` (S sinyali); `SocketVideoTransport` (`writeObservation`, `setAdmission`/`notifyReady` kaldırıldı), `VideoFrameQueue.headEnqueuedUs`; `MateBridgeHost/Video/WifiAdaptationDriver.swift` (yeniden yazıldı), `SessionServer.swift` (`VideoLink`: `attachAdaptation` kalktı, `writeObservation`); silindi: `CongestionController.swift`, `WifiAdaptation.swift` ve testleri/`CongestionReplayTrace`; testler `WifiAdaptV2Tests`, `WifiAdaptV2ReplayTests`, `WifiAdaptV2Traces` (saniyelik sayısal özet, ham log yok), `BsdTcpSocketTests` (admission testi yerine `writeObservation` testi); `docs/LOGGING.md`, `docs/KNOBS.md` satır 48, `TransportKnobs.swift` yorumu.
- **S nerede ölçülür**: `SocketVideoTransport.writeObservation()` (kernel'e verilen kümülatif bayt = biten kayıtlar + süren kaydın `size - pendingBytes` kısmı; süren yazımın başlangıcı) ve `VideoFrameQueue.headEnqueuedUs` (kuyruk başı). `SendStallDetector`: bekleyen iş var ve 150 ms bayt ilerlemesi yok -> bir olay; süren aynı takılma tekrar sayılmaz. Büyük keyframe yazımı ilerlediği için sayılmaz. 100 ms örnekleme nedeniyle takılma 150-250 ms içinde görülür (yerleşme aralığı bu).
- **Eke göre sapma/yorum** (karar kaydına yazılmadı, orkestratör onaylasın): (1) B için eşik: ek boyut vermiyor; B = tamponun hedef hızın 20 ms'i (en az 32 KiB) kadar olması ve son 300 ms'de (4 örnek) düşmemesi. Mutlak 32 KiB ile temiz oturumda 50 düşüş çıktı (o oturum dakikalarca 60-100 KB sndbuf + srtt 30-70 ms ile sorunsuz). (2) "Acil taban": 30'da ağır kanıt ilk görüldükten >= 2 sn sonra ve o tick'te YENİ kanıt (yeni takılma / D>=50&B) varsa. (3) Çıkış: adım sonrası 3 sn, tek S/D/L sonrası 2 sn bekleme; `+2 Mbps` her >= 1 sn. (4) D tabanı: boşalmış = sndbuf < 32 KiB, %10'luk dilim, >= 20 örnek (2 sn) yoksa D çalışmaz. (5) Süren tek takılma 500 ms'e varınca ağır sayılır ve adım sonrası "tüketilmiş" kalır (aynı takılma ikinci kez inmez). (6) Sürücü tavanı oturum boyunca sabit tutar (`setCeiling` denetleyicide var ve test edilmiş, sürücüye bağlanmadı: bit hızı değişimi akışı yeniden başlatıyor).
- **İz sonuçları** (tekrar testleri; 1 sn -> 100 ms eşlemesi `WifiAdaptV2ReplayTests` başlığında): 20:55:36-41 takılması: iki olay 37.3/38.3 sn, ikinci olayın tick'inde 60 -> 42 Mbps (<= 1 sn), taban altına inmez, ~9 sn'de +2/sn ile 60'a döner. 20:17 takılması: 3 olay görülür (4.'sü 170 ms, 100 ms ızgarasında kaçar), 60 -> 42, sonra takılmanın kendi retx+birikimiyle bir orta adım (35,7), min 35,7, 60'a döner. Temiz oturum (46 dk): 3 düşüş (hepsi x0,85 orta; D,B x1 + L,B x2; en düşük 51), her biri ~5 sn'de geri döner; acil yok.
- **Test**: `swift test` (taskpolicy -b) sonucu aşağıda/rapor. `./scripts/check.sh` ve Gradle çalıştırılmadı (talimat).
- **Test edilmedi**: gerçek WLAN/tablet; `VTSessionSetProperty` yolu v1 ile aynı `setTargetBitrate` (değişmedi); `writeObservation` gerçek soket üzerinde yalnız basit birim testle; sürücü (Host hedefi) birim testsiz (build geçti). Cihazda: `sent_kbps`'in `bitrate_set`'i izlemesi, gerçek takılmada `ev=adapt reason=severe`, temiz oturumda gereksiz adım sıklığı, B eşiğinin (20 ms) gerçek 100 ms örneklerde davranışı.

## Handoff — codex round 1 fixes (3 x P2)

1. **stallConsumed**: artık yalnız adım anında SÜREN bir takılma tüketilir (`stallActiveNow`); yeni başlayan takılma (`stallStarted`) ya da bitmiş olan taze sayılır. D/B ya da L/B adımının hemen ardından başlayan takılma 500 ms'de ağır adım verir (test: `testStallRightAfterANonStallStepIsNotConsumed`, `testStallRunningAtAStepIsConsumedAndANewOneIsFresh`). Poll'lar arasında biten takılma uzunluğuyla gelir (`Sample.stallEndedMs`, >= 500 ms tek başına ağır; adım anında açık sayılmış bir takılmanın bitişi tekrar sayılmaz).
2. **Tutarlı snapshot**: transport'taki ayrı kilitli bayt/`pendingBytes` okuması kalktı. `BsdTcpConnection.writeProgressSnapshot()` kabul edilen bayt, bekleyen bayt ve boşluk süresini TEK kilit altında verir (`WriteGapMeter.Snapshot`); transport yalnız iletir (`completedBytes/writeBytes/writeStartedUs` ve `clockUs` silindi). Test: `testWriteProgressSnapshotIsConsistentAcrossRecordTransitions` (arka arkaya kayıtlar, ayrı iş parçacığında örnekleme: accepted ve accepted+pending asla azalmaz, sonda toplam eşit) ve `WriteGapMeterTests.testRecordTransitionDoesNotMixTheGaps`.
3. **Yazıcı tarafı zamanlama**: yeni saf `WriteGapMeter` (Core/Video), `BsdTcpConnection` kilidi altında `drainLocked`'da baytlar kernel'e girdiği anı damgalar. >= 150 ms ilerlemesiz bekleyen kayıt, poll'lar arasında bitse bile sayılır (`longGapsEnded`), açık olan tam ölçülür (`openGapNs`). `SendStallDetector` yeniden yazıldı: yazıcı boşluğu (faz bağımsız) + yazım yokken kuyruk başı yaşı (yaş tam, son ilerleme yazıcıdan; yalnız poll anında AÇIK kuyruk-başı takılması görülür, 150-250 ms'lik kuyruk-başı takılması iki poll arasında bitebilir: kalan sınırlama). Testler: `WriteGapMeterTests` faz 0..99 ms taraması 160/220/500 ms (her fazda tam 1 olay), 140 ms hiç, her saniye tekrarlayan 220 ms (3/3), büyük ilerleyen yazım 0, kayıt geçişi.
- **İz sayıları değişti (durumlar)**: 20:17 takılması artık 4 olay (önce 3): 60 -> 42 (severe) -> 35,7 (moderate L,B) -> 30 (severe, taban), min 30. 20:55 takılması 4 olay (önce 2): 60 -> 42 -> 30 (taban), min 30, ~20 sn'de 60'a döner. Acil taban yok. **Temiz oturum aynı**: 3 düşüş / 46 dk (D,B x1; L,B x2), min 51. Not: 20:55 olayı artık tabana iniyor (4 ardışık ~220 ms takılma, 4 s); önceki turdaki 42'de kalma 100 ms ızgara kaçırmasının sonucuydu.
- Tam `swift test` (taskpolicy -b) sonucu rapor mesajında.

## Open questions

- B eşiği (20 ms hız, >= 32 KiB) ve acil taban "yeni kanıt" şartı ek metninde yok; yukarıdaki sapma listesi 0023 ekine işlenmeli mi?
- 100 ms ızgarası 150-170 ms'lik takılmaları kaçırabilir (20:17 olayının 4. saniyesi). Gerekirse detector tick yerine yazım tamamlanma süresini (`writeDoneUs - writeStartUs >= 150 ms`) ek kanıt olarak alabilir; ek karar gerektirir.
- Temiz oturumda L,B ile 2 düşüş çıktı (retx 4-5 paket/sn, ~190-205 KB tampon): kabul sınırının içinde ama cihaz A/B'sinde izlenmeli.
