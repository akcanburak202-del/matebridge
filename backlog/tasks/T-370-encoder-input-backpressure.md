---
id: T-370
title: Host — kodlayıcı girişinde geri basınç: kuyruk/aktarım doluyken yakalamayı VT'ye verme (zorunlu IDR zincirini kes)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-368, T-369]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Video/EncoderSubmitOrder.swift
  - host-mac/Sources/MateBridgeCore/Video/FrameGate.swift
  - host-mac/Sources/MateBridgeCore/Video/BoundedFrameQueue.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoFrameQueue.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-370-encoder-input-backpressure.md
---

## Amaç

`docs/research/2026-10-23-forced-idr-chain.md` seçenek A. Wi-Fi radyo kaybında kodlanmış delta'lar 2 karelik kuyrukta taşıp zinciri kırıyor → host IDR zorluyor → büyük IDR yine taşırıyor (§1 halka 3, 7). Yakalamayı **kodlamadan önce** atlamak (FramePacer ezmesi) zinciri kırmaz. Kodlayıcıya yeni kare verme kararı, VT içindekiyle birlikte kuyruk + aktarım doluluğunu da saymalı.

## Kabul

1. **Önce kırmızı test** (saf, `EncoderSubmitOrder`/`FramePacer`/`BoundedFrameQueue` seviyesinde): 60 fps girdi; aktarım bir süre (ör. 200 ms) yavaş/kapalı; bugünkü kodda kuyruk taşar ve `keyframeNeeded` çağrılır (kırmızı, Handoff'ta çıktı). Düzeltmeyle aynı senaryoda `keyframeNeeded` çağrılmaz, kareler kodlamadan önce ezilir (`overwritten` artar), aktarım açılınca en geç 1–2 kare içinde akış sürer.
2. Sağlıklı akışta davranış değişmez: aktarım hızlıyken hiçbir yakalama fazladan atlanmaz, gecikme eklenmez (test: sürekli hızlı aktarımda `overwritten` = 0, `gate_wait` aynı). T-365/T-368 testleri geçer.
3. İstemci `keyframe_request`, periyodik, yeni tüketici IDR yolları değişmez. Paketli tam renk (aux) akışı: ya aynı kural uygulanır ya da Handoff'ta neden uygulanmadığı yazılır.
4. "Newest wins" korunur: geri basınç yalnız kodlanmamış yakalamaları ezer; kuyruk sınırı aynı.
5. LOGGING.md: yeni sayaç/alan varsa (ör. `cadence` içinde `backpressured=`).
6. `./scripts/check.sh` geçer. Çalışan uygulamaya dokunma, Mac'te pencere açma, cihaz testi yok.

## Plan

`EncoderSubmitOrder` kodlayıcıya yeni kare verirken VT içindekine ek olarak çıkış kuyruğunu sayar: `inFlight + queuedCount < queue kapasitesi (2)` değilse yakalama pacer'da bekletilir/ezilir (`overwritten`). Bekleme için kuyrukta serbest bırakma geri çağrısı yok, 1,5 ms'lik flush yoklaması kullanılır. Bekleyen keyframe isteği ve `bypassGate` (IDR yeniden gönderimi) engellenmez. `HEVCEncoder` yeni `downstreamLoad` parametresini iletir, `VideoPipeline` tek satırla `max(main, aux kuyruk sayısı)` verir.

## Handoff

- Dal: task/T-370-encoder-input-backpressure. Commit SHA: d1f2545f (main e5370de8 üzerine rebase edilmiş, T-371 dahil).
- Dosyalar: MateBridgeCore/Video/EncoderSubmitOrder.swift, VideoFrameQueue.swift (`queuedCount`), MateBridgeHost/Video/HEVCEncoder.swift, VideoPipeline.swift (+2 satır), Tests/.../Video/EncoderBackPressureTests.swift (yeni), docs/LOGGING.md, bu kart. FrameGate/BoundedFrameQueue/EncoderSubmitOrder dışı Core dosyalarına dokunulmadı.
- **Kırmızı çıktı (düzeltme öncesi, parametreler yalnız kabul edilip yok sayılırken):** testStalledTransportDoesNotOverflowQueueOrForceKeyframe: `("1") is not equal to ("0") - no encoded frame was dropped, so no keyframe is needed` (keyframeNeeded 1 kez çağrıldı); `discardedCount ("12") is not equal to ("0")`; `overwritten ("0") is not greater than ("0")`; ve aktarım açıldıktan sonra `keyframeNeeded ("1") != 0`. Senaryo: 60 fps, 5 kare sağlıklı, 200 ms aktarım kapalı (12 kare), sonra açık.
- Düzeltme sonrası: 3 yeni test yeşil (durma: needed=0, discarded=0, overwritten>0, açılınca 2 kare içinde akış; sağlıklı 120 kare: overwritten=0, 120 kodlanmış; bekleyen keyframe engellenmez). Rebase sonrası `swift test` 709 test 0 hata. check.sh: host OK; gradle 2 test kırmızı (T-367 flaky zamanlama testleri, Android'e dokunulmadı).
- Kararlar: yeni log alanı yok (kuyruk ezmesi mevcut `overwritten` içinde; `Stats.backPressureHolds` yalnız tanılama), LOGGING.md'ye bir madde. Aux (paketli) akış: aynı kural, kuyruk sayısı `max(ana, aux)`; aux kodlayıcı ana kareyle birlikte tek submit'ten beslendiği için ayrı kapı yok.
- Varsayım: kuyruk kapasitesi 2 ve `inFlight + queued >= 2` ise tutma. Geçici olarak sender bir kareyi pop etmeden iki yakalama arka arkaya gelirse bir yakalama bir sonraki 1,5 ms yoklamasına kadar bekler (kayıp değil, yalnız en yenisi kazanır).
- Cihazda doğrulanacak: T-366 dummynet enjektörü ile önce/sonra (olay başına `idr`, `queue_drops`, `cap_dec_ms`, `overwritten`); sağlıklı Oyun 60'ta `overwritten`/`gate_wait` değişmedi mi; T-371 IDR neden günlüğünde `queue_overflow` nedeni azalıyor mu.


## Open questions

### Codex P2 düzeltmesi (yardımcı akış uçuştaki kareler)
- Kırmızı (düzeltme öncesi, testAuxiliaryFramesStillEncodingCountAgainstTheAuxiliaryQueue): `("3") is not equal to ("2") - B waits: A is still encoding...`; `needed ("1") != 0`; `discardedCount ("2") != 0` (B kabul edildi, A ve B yardımcı kuyruğu taşırdı).
- Düzeltme: `DownstreamBudget.projected` = max(ana uçuş + ana kuyruk, yardımcı uçuş + yardımcı kuyruk); `EncoderSubmitOrder` kapısı artık `downstreamLoad(mainInFlight)` ile bu doluluğu kapasiteyle karşılaştırır. Yardımcı uçuş sayısını `AuxInFlightTracker` (Core) tutar: HEVCEncoder submit öncesi `began`, yardımcı çıktı/kayıp/ret'te `ended`; çözülmeyen kayıt 250 ms sonra unutulur (sayaç kayması yakalamayı kalıcı tutamaz). `PackedAuxEncoder.swift` dosya listesi dışı olduğu için dokunulmadı. `HEVCEncoder.downstreamLoad` parametresi `queuedFrames` (ana, yardımcı) oldu; VideoPipeline'da aynı tek ifade.
- swift test: 711 test, 0 hata. Kod commit SHA: bkz. git log (`T-370: count auxiliary frames in flight`).
