---
id: T-369
title: Tasarım — Wi-Fi kaybından sonra zorunlu IDR zinciri (0,2–0,4 sn donma) yerine daha ucuz toparlanma
status: todo
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/research/2026-10-23-forced-idr-chain.md
  - backlog/tasks/T-369-forced-idr-chain-design.md
---

## Amaç

Kanıt: NOTES 2026-10-23 öğleden sonra ("30 Mbps neden kötü göründü") ve akşam ("knob kapalı oyun oturumu"). Tek bir Wi-Fi radyo kaybı (retx 1) TCP `snd_cwnd`'yi 284 KB → 48 KB'ye indiriyor; 60 Mbps'te kare başına ~125 KB olduğundan host kuyruğu taşıyor (`queue_drops`, `overwritten`), `VideoSender` kare düştüğü için IDR zorluyor (`KeyframeRequestCoalescer`), 490–884 KB IDR'ler zaten daralmış bağlantıya gidiyor → saniyede 3–4 IDR, tablet 3–20 fps, 0,2–0,4 sn donma. 20 dk'da ~20 olay, 82 IDR. `MATEBRIDGE_WIFI_ADAPT` aynı döngüyü büyüttü (NOTES 2026-10-23 akşam ilk satır).

Bu kart **yalnız araştırma + tasarım**: kod yok. Çıktı `docs/research/2026-10-23-forced-idr-chain.md`.

## Sorular

1. Kodda hangi düşüş hangi yoldan IDR doğuruyor (`VideoSender` 137/155/215 civarı, `KeyframeResync`, `KeyframeRequestCoalescer`, `VideoFrameQueue`, `overwritten` yolu, istemcinin `keyframe_request`'i)? Zincirin her halkası dosya:satır ile.
2. Seçenekler, maliyet/risk ile: (a) düşen kare referans olmadıkça IDR zorlamamak (HEVC'de VideoToolbox ile referans yapısı: hiyerarşik değil, her P bir öncekine bağlı → düşen her P sonrakileri bozar mı?), (b) IDR yerine "intra refresh"/yavaş tazeleme ya da `kVTEncodeFrameOptionKey_ForceKeyFrame` yerine daha küçük I (QP/boyut tavanı), (c) uzun dönem referans (LTR) — VideoToolbox HEVC'de destek ve tablet MediaCodec çözücüsü, (d) düşürmek yerine kuyrukta tutmak (gecikme ↔ donma), (e) IDR'leri ardışık zorlamayı sınırlamak (ilk IDR teslim edilmeden yenisini istememe), (f) IDR boyutunu `DataRateLimits` ile sınırlamak. Her biri için protokol etkisi (PROTOCOL.md değişir mi), istemci değişikliği, beklenen etki.
3. Ölçüm planı: T-366 `stall-inject.sh` ile önce/sonra (kol başına ~9 olay, 60 Mbps); başarı ölçütü (olay başına IDR sayısı, en büyük `cap_dec_ms`, toparlanma süresi).
4. Öneri: hangi seçenek(ler), kaç kart, hangi sırayla.

## Plan

## Handoff

Çıktı: `docs/research/2026-10-23-forced-idr-chain.md`. Öneri: T-370 kodlayıcı girişinde geri basınç, T-371 IDR neden günlüğü, T-372 koşullu (IDR arkası delta tutma), T-373 LTR araştırması. Test edilmedi: cihaz/dnctl koşusu yok; Android MediaFormat dokümanı okunamadı (doğrulanmadı olarak işaretli). VT yoklaması geçici sondayla (depoda yok).

## Open questions
