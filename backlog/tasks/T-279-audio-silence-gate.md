---
id: T-279
title: Host — tamamen sıfır sesi gönderme (sessizlik kapısı)
status: in_progress
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0011]
files:
  - host-mac/Sources/MateBridgeCore/Audio/
  - host-mac/Tests/MateBridgeCoreTests/Audio/
  - backlog/tasks/T-279-audio-silence-gate.md
---

## Amaç

Mac'te bir uygulama ses cihazını açık tutup sessizlik çalınca (tarayıcı sekmesi, oyun) tap IO'su durmuyor. O sırada host saniyede 100 paket sıfır PCM gönderiyor (~1,5 Mbps). 2026-10-06 host logunda sesli saniyelerin %25'i `rms_dbfs=-120.0`. Karar 0011 güncellemesi: host tamamen sıfır sesi göndermesin. **Protokol değişmez.**

## Kabul

1. Gönderici (`AudioStreamer.drain`, gerçek zamanlı iş parçacığı **değil**) her paketin tamamen sıfır olup olmadığını bilir. Ölçüt: s16'ya çevrilmiş her örnek 0. `sumSquares` s16 üzerinden hesaplanıyorsa `== 0` yeterli; değilse gerekeni ekle. Gerçek zamanlı yolda kilit, ayırma ve log olmaz.
2. Arka arkaya **500 ms** (50 paket) tamamen sıfır paket gelince sonraki sıfır paketler gönderilmez. İlk sıfır olmayan paket, kapı kapalıyken de gönderilir. Bekleme süresi sabit bir değerdir; geliştirici ortam değişkeni gerekmez.
3. `seq` ardışık kalır (gönderilen paket sayacı). Atlanan paketlerin `sample_index` ve `capture_time_us` değerleri bir sonraki gönderilen pakette sıçrama olarak görünür. Bu, tap IO'sunun durmasıyla aynı görünüm. İstemcinin `PlayoutCore` "idle gap" sınıflaması (sıçrama ≥ 20 ms) bunu alt taşma saymaz; doğrula, istemci koduna dokunma.
4. Saniyelik `audio ev=stats` satırı: `packets` gönderileni sayar. Yeni alan `silent_skipped=<n>`. Mevcut alanların sırası ve anlamı değişmez. `rms_dbfs` gönderilen paketlerden hesaplanır.
5. Akış başlarken, yeni `stream_id` ile ve oturum değişince sayaç sıfırlanır. İlk paketler sıfır olsa bile akışın ilk paketi gönderilir; istemci `AUDIO_CONFIG` sonrası bir paket görmeli.
6. Testler: 50 sıfır paketten sonra atlama, sıfır olmayan pakette sürme ve `seq`'in ardışık kalması, kısa sessizliğin (< 500 ms) aynen gitmesi, ilk paket kuralı, `-90 dBFS` (1 LSB) paketin sıfır sayılmaması, stats alanı.
7. `./scripts/check.sh`. Mac'te pencere açma.

## Plan

## Handoff

## Open questions
