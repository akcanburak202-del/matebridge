---
id: T-327
title: Core — saf Wi-Fi tıkanıklık denetleyicisi (uçuştaki bayt bütçesi, hızlı in / yavaş çık), 2026-10-09 Oyun izinden altın tekrar
status: done
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0023]
files:
  - host-mac/Sources/MateBridgeCore/Session/CongestionController.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/CongestionControllerTests.swift
  - host-mac/Tests/MateBridgeCoreTests/Session/CongestionReplayTrace.swift
  - backlog/tasks/T-327-core-congestion-controller.md
---

## Amaç

0023 (c) dalı 2026-10-09'da yeniden açıldı (karar eki). Bu kart, 2026-10-04'te uygulanmadan kapatılan **T-195**'in yeniden açılışıdır: G/Ç'siz, saat okumayan, log yazmayan saf bir denetleyici. Girdi: kare yazımları, saniyelik/100 ms TCP anlık görüntüleri, host kuyruk düşüşleri. Çıktı: (a) yeni kare kabulü (uçuştaki bayt bütçesi), (b) [taban, tavan] aralığında hedef bit hızı.

## Bağlam

- **Tasarım:** `backlog/tasks/T-195-core-congestion-controller.md` *Bağlam* ve *Kabul kriterleri* aynen geçerli (girdi/çıktı şekli, pencereli minimum srtt tabanı, bütçe ≈ hedef × 20 ms ve en az bir ortalama kare, ×0,7 hızlı in en çok srtt başına bir, sessizlikten sonra tavanın %5'i/s yavaş çık, `unackedBytesEstimate` KULLANMA → `sendBufferBytes`). Oradaki dosya/satır numaraları a30c769'dan; HEAD'de yeniden doğrula (`TcpInfoLog.swift` `TcpConnectionSnapshot`, `StreamPrefsPolicy.swift` bit hızı varsayılanları).
- **Sinyal notu (2026-10-08/09 cihaz verisi):** tıkanıklık anlarında video soketinde yeniden gönderimler ve host `queue_drops` görüldü, kontrol srtt 58–70 ms'ye çıktı (taban ~2–5 ms). Yani T-195'in "kayıp yok, yalnız kuyruk" varsayımı artık tam doğru değil: yeniden gönderim deltası da hızlı in tetikleyicisi olmalı.
- **Altın tekrar izi:** T-127 izi yerine bugünkü gerçek Oyun oturumunu kullan: `~/Library/Logs/MateBridge/host.log`, oturum `sid=4258627209`, 2026-10-09 tablet saatiyle 16:50:12–16:56 (host mono ≈ tablet + 5,1 s; `stream_config` host mono 75341992 = tablet 16:50:12.878). Video bağlantısının saniyelik `ev=tcp` satırlarından (bkz. `docs/LOGGING.md`) yalnız sayılar: saniye, srtt, rttcur, sbbytes/notsent, retx deltası, video bayt/s, `queue_drops`. Ham log commit edilmez; yalnız sayı dizisi Swift literal olarak `CongestionReplayTrace.swift`'e (kişisel veri/seri no yok). İzde 16:51:00, 16:54:19, 16:54:26 kuyruk düşüşleri ve oyun başındaki 385 yeniden gönderim patlaması var; denetleyici bu anlarda inmeli, temiz dakikalarda tavana dönmeli.
- Tavan = oturumun yapılandırılmış bit hızı; taban önerisi 12 Mbps (bir keyframe'i taşıyabilmeli; gerekçeyi Plan'a yaz).

## Kapsam dışı

- Gönderim kapısına/kodlayıcıya bağlama, anahtar, log (T-328). İstemci, UDP/QUIC, tel.

## Kabul kriterleri

- [ ] T-195 *Kabul kriterleri*'nin tamamı (adım tepkisi, sınırlar, salınımsızlık, kabul/bütçe, kuyruk düşüşünde srtt başına tek iniş, altın tekrar, G/Ç/saat/log yok).
- [ ] [XCTest] Yeniden gönderim deltası > 0 olan saniye hızlı in tetikler (srtt başına en çok bir).
- [ ] [XCTest] Altın tekrar: 2026-10-09 izinde düşüş anlarında hedef iner; düşüşsüz son 60 s içinde tavana döner. Beklenen dizi testte saklı.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `CongestionController` (saf değer tipi, `Sendable`, G/Ç/saat/log yok; zaman µs argüman). Girdiler: `frameWritten(bytes:)` (ortalama kare EWMA), `tick(CongestionTick)` (nowUs, srttMs, sendBufferBytes = `tcpi_snd_sbbytes`, retransmitPacketsDelta; `TcpInfoReport` köprüsü var), `queueDropped(nowUs:)`. Çıktılar: `mayWrite(sendBufferBytes:)` (kabul), `budgetBytes`, `targetKbps` [taban, tavan] (250 kbps adımına nicemlenir).
2. Tetikleyiciler (herhangi biri hızlı in): yeniden gönderim deltası > 0; srtt - pencereli min srtt >= 20 ms; sbbytes > 3 x bütçe; host kuyruk düşüşü. Hızlı in x0,7, iki iniş arası en az max(srtt, 250 ms) (kart: "srtt başına en çok bir"; 250 ms alt sınır 100 ms tick'te art arda inişi önler). Her tetikleyici sessizlik sayacını sıfırlar (inişe dönüşmese de).
3. Yavaş çıkış: son tetikleyiciden 2 s sonra tavanın %5'i/s (dt ile sürekli). Hiç tetikleyici yokken hedef = tavan, salınım yok.
4. Bütçe = max(hedef x 20 ms, ortalama kare); sbbytes <= bütçe ise kabul. `unackedBytesEstimate` kullanılmaz.
5. Taban 12 Mbps (min(12000, tavan)): bir keyframe taşınabilmeli. Oyun izinde keyframe 240-680 KB; 12 Mbps'te 8 Mbit/12 = ~0,3-0,45 s'de boşalır (tavanda 0,07 s). Taban altı keyframe/aralık bütçesi bozulur, üstü temiz gün/kötü gün farkını (30 Mbps temiz, 60 Mbps kuyruk) kapsar. srtt taban penceresi 30 s (10 s değil: oyun başı yoğun dönem 9 s sürüyor, 10 s'de taban kayardı).
6. Altın tekrar: ham log commit edilmez; 2026-10-09 Oyun izinden 1 s çözünürlüklü yalnız sayılar (srtt, rttcur, sbbytes, retx, sent_frames, sent_kbps, queue_drops) `CongestionReplayTrace.swift`'e Swift literal; beklenen hedef dizisi testte saklı. Tavan 60000 kbps. Replay açık döngü (iz denetleyicisiz kaydedildi): denetleyici düşüş anlarında inmeli, son düşüşsüz 60 s'de tavana dönmeli.
7. Testler (swift-testing, projenin biçimi; kartta "XCTest" yazıyor ama paket Testing kullanıyor): adım tepkisi, sınırlar, salınımsızlık, kabul/bütçe, düşüşte srtt başına tek iniş, retx tetikleyici, altın tekrar.
Riskler: tek paketlik retx'ler (iz boyunca ~10 s'de bir) tavandan sürekli küçük inişler yaratabilir; altın tekrarda ölçülür, gerekirse küçük-retx için hafif iniş çarpanı.

## Handoff

- **Commit:** (aşağıdaki commit; SHA orkestratör raporunda)
- **Dokunulan dosyalar:** `host-mac/Sources/MateBridgeCore/Session/CongestionController.swift`, `host-mac/Tests/MateBridgeCoreTests/Session/CongestionControllerTests.swift`, `host-mac/Tests/MateBridgeCoreTests/Session/CongestionReplayTrace.swift`, bu kart. (Kartın `files:` listesindeki yol `Session/`; T-195'teki `Video/` değil.)
- **API:** `CongestionController(config: .init(ceilingKbps:floorKbps:framesPerSecond:))`; `frameWritten(bytes:)`, `tick(.init(nowUs:srttMs:sendBufferBytes:retransmitPacketsDelta:))` (veya `Tick(nowUs:report: TcpInfoReport)`), `queueDropped(nowUs:)` -> Bool; çıktılar `targetKbps` (250 kbps adım), `budgetBytes`, `mayWrite(sendBufferBytes:)`, `baselineSrttMs`. `tick`/`queueDropped` inişin nedenini (`Trigger`) / Bool döner, T-328 logu için.
- **Sabitler (hepsi `static let`, gerekçeli):** taban 12 Mbps (min(12000, tavan)); hızlı in x0,7; en çok max(srtt, 250 ms)'te bir iniş; sessizlik 2 s, sonra tavanın %5'i/s; srtt tetikleyici = pencereli min + 20 ms; sbbytes tetikleyici = 3 x bütçe; bütçe = max(hedef x 20 ms, ortalama kare); srtt taban penceresi 30 s (1 s kovalar); tek-iki paketlik retx (< 4 paket/pencere) yalnız x0,9.
- **Varsayımlar / karttan sapmalar:**
  - Kart "retx delta > 0 hızlı in tetikler" diyor; tetikler, ama iz boyunca 10-20 s'de bir görülen 1-3 paketlik tek retx'ler (sağlıklı RTT'de Wi-Fi kuyruk kaybı) x0,7 ile tavandan %30'luk testere dişi yaratıyordu (ilk tekrar). 4 paketten azında x0,9 kullanıldı; 385 paketlik patlama tam x0,7. Sabit `mildRetransmitPackets`/`mildDownFactor`; sıfıra çekilirse kart metnine birebir döner.
  - Kartta "XCTest" yazıyor; pakette swift-testing kullanılıyor, testler onunla.
  - Altın tekrar açık döngü (iz denetleyicisiz kaydedildi) ve 1 s çözünürlüklü; `sent_frames/sent_kbps` ile `net ev=stats` saatleri tcp tick'ine göre kayıyor, bu yüzden ortalama kare boyutu yaklaşık (yalnız bütçe tabanını etkiler). Beklenen dizi `CongestionReplayTests.expectedTargets` içinde; sabit değişirse bilerek yeniden kaydedilir.
  - `queueDropped` hangi düşüşleri raporlayacağı T-328'in kararı: kapının kendi reddettiği kareler raporlanırsa kendi kendini besleyen bir iniş döngüsü olur.
- **Test edilmeyenler / cihazda doğrulanacaklar:** hiçbir şey cihazda çalışmadı (saf mantık). Kapalı döngü davranış (hedef düşünce iz gerçekten düzelir mi, 100 ms tick'lerde srtt için 250 ms alt sınırı, bütçenin kapıyı gereksiz kısması) yalnız T-328 bağlandıktan sonra tablette A/B ile görülür. Sabitler 2026-10-09 tek oturumundan kalibre; başka WLAN'da ayar gerekebilir.
- **Açık sorular:** yok.

## Open questions
