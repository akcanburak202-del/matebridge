---
id: T-370
title: Host — kodlayıcı girişinde geri basınç: kuyruk/aktarım doluyken yakalamayı VT'ye verme (zorunlu IDR zincirini kes)
status: todo
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

(ajan yazar)

## Handoff

## Open questions
