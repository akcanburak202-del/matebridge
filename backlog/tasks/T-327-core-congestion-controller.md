---
id: T-327
title: Core — saf Wi-Fi tıkanıklık denetleyicisi (uçuştaki bayt bütçesi, hızlı in / yavaş çık), 2026-10-09 Oyun izinden altın tekrar
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

## Open questions
