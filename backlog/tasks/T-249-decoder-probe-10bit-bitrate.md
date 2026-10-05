---
id: T-249
title: Probe — decoder headroom for 10-bit (SDR + HDR PQ) and high bitrates (60–150 Mbps) at 2800×1840
status: ready
phase: 6
owner: android-client-dev
depends_on: [T-248]
decisions: [0032]
files:
  - probes/decoder-concurrency-probe/
  - probes/README.md
  - backlog/tasks/T-249-decoder-probe-10bit-bitrate.md
---

## Amaç

T-248 tablet çözücüsünün 8-bit 2800×1840 @60 Mbps'te ~356 fps verdiğini, 120 fps tempolu beslemede kare başına gecikmenin p50/p95 13,3/16,6 ms olduğunu gösterdi. "Çözücü sınırda" varsayımıyla konan sınırları kaldırmadan önce iki açık soru (NOTES 2026-10-05 ~17:20):

1. **10-bit:** HEVC Main10 (HDR10 PQ/BT.2020 ve SDR BT.709 10-bit) çözme kapasitesi ve gecikmesi 8-bit ile aynı mı? → 0032 "HDR yalnız Oyun 60" çekincesi, 10-bit SDR (bantlanma) fikri.
2. **Bit hızı:** 60 / 80 / 100 / 150 Mbps'te kapasite ve gecikme (özellikle p99/maks) nasıl değişiyor? → T-085'in +2–3 ms ve p99 40 ms bulgusu çözücüden mi geliyordu; Oyun/Çizim Otomatik 60 Mbps ve host 80 Mbps tavanı.

İsteğe bağlı (ucuz ise): IDR kare çözme gecikmesi (periyodik IDR'li klip) → kurtarma maliyeti.

## Bağlam

- Ürün koduna dokunma; yalnız mevcut prob genişletilir (`probes/decoder-concurrency-probe/`, Swift klip üreteci + Android `dev.matebridge.decprobe`). T-248 kartındaki düzen ve çalıştırma bloğu geçerli.
- **Klip üreteci:** bit derinliği/renk seçeneği (`8` mevcut; `10sdr` = Main10 BT.709; `10pq` = Main10 BT.2020/PQ, MDCV+CLL SEI — örnek: `probes/hdr-probe/Sources/hdr-probe/EncodeBench.swift` ve host HDR yolu 0032) ve hedef bit hızı seçeneği. Dosya adı bunları içersin (ör. `full_2800x1840_10pq_100m.h265`). Kolay içerik VT'nin hedef bit hızına ulaşmasını engelleyebilir: gren/gürültü düzeyi ayarlanabilir olsun ve **gerçekleşen Mbps** üretimde yazılsın; hedeften %15'ten fazla sapan klip açıkça işaretlensin. Varsayılan set: full 2800×1840 × {8, 10sdr, 10pq} @60 Mbps + 8 ve 10pq × {80, 100, 150} Mbps. İsteğe bağlı: 8-bit 60 Mbps `idr=60` (her 60 karede IDR).
- **Android probu:** yeni dosya adlarını tanısın (ad → boyut/biçim çözümleme), 10-bit çıkışta `ImageReader` biçimi uygun seçilsin (PRIVATE çalışmazsa açıkça `ERR` yaz, sessizce düşme). İstatistiklere **p99 ve maks** gecikme ile çıkışlar arası p99 eklensin; IDR'li klipte IDR karelerinin gecikmesi ayrıca raporlansın. Kullanılan çözücü adı ve profil (`Main10`, `Main10HDR10`) satırda görünsün.
- Probu orkestratör çalıştıracak (MateBridge kapalıyken, tek cihaz testi). Kartın Handoff'una T-248'deki gibi kopyala-yapıştır çalıştırma bloğu yaz: sınırsız (`image`) ve `pace=120` + `pace=60` koşuları, tüm klipler.
- Mac'te pencere açma, sanal ekran kurma; kısa VT kodlama serbest. adb/tablet yok.

## Kabul kriterleri

- [ ] Klip üreteci yeni seçeneklerle derlenir ve varsayılan seti `~/.cache/matebridge-tools/data/decprobe/` altına üretir; her klip için gerçekleşen Mbps + AU sayısı doğrulanır; 10-bit kliplerde SPS'te `bit_depth_luma=10` ve doğru renk VUI'si (test ya da üretim sonu kontrolü).
- [ ] Android probu `assembleDebug testDebugUnitTest` geçer; yeni JVM testleri ad çözümleme + p99/maks hesabı.
- [ ] `./scripts/check.sh` geçer.
- [ ] Handoff: çalıştırma bloğu ve sonuç yorumu rehberi (10-bit ≈ 8-bit mi; bit hızıyla gecikme kuyruğu nasıl büyür; hangi sonuç hangi kararı/sınırı değiştirir).

## Plan

(boş — ajan doldurur)

## Handoff

## Open questions
