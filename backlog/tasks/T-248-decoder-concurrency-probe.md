---
id: T-248
title: Probe — does the tablet's HEVC decoder scale with concurrent sessions? (1 vs 2 vs 3 decoders, full vs half frames)
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: []
files:
  - probes/decoder-concurrency-probe/
  - probes/README.md
  - backlog/tasks/T-248-decoder-concurrency-probe.md
---

## Amaç

Kullanıcı 2026-10-05: çözücü sınırını aşmak için görüntüyü iki yarıya bölüp iki çözücü oturumunda çözmek mümkün mü? Tablet `media_codecs*.xml`: `OMX.hisi.video.decoder.hevc` `concurrent-instances max=16`, `performance-point-4096x2160=60`, ölçülmüş 1080p 258 fps (535 Mpx/s), 4K 71 fps (589 Mpx/s), 720p 267 fps (246 Mpx/s → kare başına ~3,7 ms sabit maliyet). Soru: eş zamanlı oturumlar toplam hızı artırıyor mu (çok çekirdek), yoksa aynı hattı mı paylaşıyor?

## Bağlam

- Ürün koduna dokunma. `probes/decoder-concurrency-probe/`: (a) Mac tarafı küçük Swift CLI (diğer problar gibi; `probes/hdr-probe/Sources/hdr-probe/EncodeBench.swift` VT kodlama örneği): gerçekçi içerikli (kayan yazı + fotoğraf hareketi) 8-bit HEVC klipler üretir, MateBridge'in hızlı profiline yakın ayarlarla (B-kare yok, düşük gecikme dışı hızlı yol, ~60 Mbps eşdeğeri): `full_2800x1840.h265` ve `half_1400x1840.h265` (ve isteğe bağlı `quarter`), her biri ~600 kare, Annex-B. (b) Android probu (`probes/hdr-probe/android` düzeninde ayrı paket `dev.matebridge.decprobe`): klipleri `/sdcard/Android/data/<pkg>/files/`'tan okur; N ∈ {1,2,3} eş zamanlı `MediaCodec` (her biri kendi iş parçacığında, aynı ya da farklı klip) mümkün olan en hızlı şekilde çözer; çıkış ya `ImageReader` (gösterimsiz, hemen bırak) ya da yüzeysiz ByteBuffer — ikisi de denensin; `KEY_OPERATING_RATE` Short.MAX ve `KEY_PRIORITY 0` (MateBridge T-222 gibi) ile. Ölçüm: her oturum ve toplam kare/s, Mpx/s, kare başına süre p50/p95; senaryolar: 1×full, 2×full, 1×half, 2×half, 3×half. Sonuç logcat'e `DECPROBE` etiketiyle tek satır özet + istenirse dosyaya.
- Probu orkestratör kuracak ve çalıştıracak (MateBridge kapalıyken, ~3 dk). Komutları README'ye yaz.
- check.sh Swift probunu derler; Android probu alt klasörde, elle derlenir (hdr-probe gibi) — README'de komut.
- Mac'te pencere açma, sanal ekran kurma; kısa VT kodlama serbest. adb/tablet yok.

## Kabul kriterleri

- [ ] Swift CLI derlenir ve klipleri üretir (`~/.cache/matebridge-tools/data/decprobe/`); `./scripts/check.sh` geçer.
- [ ] Android probu `assembleDebug` ile derlenir; README'de kurulum/çalıştırma/okuma komutları.
- [ ] Handoff: beklenen sonuç yorumu (2×half toplam ≈ 2× 1×half Mpx/s → çok çekirdek; ≈ aynı → tek hat).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
