---
id: T-237
title: Host — HDR10 per decision 0032 (STREAM_PREFS dynamic_range codec + HDR display, SCK HDR capture, VT Main10 PQ, SDR fallback)
status: todo
phase: 6
owner: mac-host-dev
depends_on: [T-232]
decisions: [0032]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/VirtualDisplay.swift
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-237-host-hdr10-pipeline.md
---

## Amaç

Decision 0032'nin host tarafı. Protokol (PROTOCOL.md §0x03 HDR10 notu, §0x05 `dynamic_range` grubu ve host kuralı) ve fixture'lar (`stream_prefs_hdr`, `stream_config_hdr10`, `invalid_stream_prefs_hdr_partial`) orkestratörün `task/T-236-hdr-protocol` dalında. **Bu dalın üzerine kur** (`git checkout -b task/T-237-host-hdr10 task/T-236-hdr-protocol`). Protokolü değiştirme; uyuşmazlık görürsen kartın Açık sorular'ına yaz.

## Bağlam

- Codec: `STREAM_PREFS` 8 / 12 / ≥14 bayt, 9–11 ve 13 kısa; fixture testleri (her fixture'ın test kaydı: `FixtureTests.everyFixtureFileHasATestCase`). `StreamPrefsPolicy`/`StreamPrefsStore` (cihaz başına hatırlanan tercih, T-049) `dynamic_range`'i de tutar.
- Ekran: `dynamic_range=1` → T-232'deki `transferFunction=1` yolu (`VirtualDisplay`, özel API yalnız orada), ekran kipi değişimi gibi yeniden kurma. Oyun ekranı (0029) ile birlikte çalışır.
- Yakalama: SCK HDR — araştırma §2 ve `probes/hdr-probe/Sources/hdr-probe/Capture.swift` (`captureDynamicRange`, `x420`, `colorSpaceName` itur_2100_PQ). Kodlama: `probes/hdr-probe/Sources/hdr-probe/EncodeBench.swift` (Main10 PQ, MDCV/CLL, `HDRMetadataInsertionMode`, hızlı profil; 120 fps p50 5,6 ms ölçüldü). Girdi etiketlerini 2020/PQ/2020'ye yeniden yaz (T-113 `HEVCEncoder` deseni). Meta veri değerleri: MDCV P3-D65 1000 nit (prob değerleri), CLL 1000/400 başlangıç; planda gerekçelendir.
- `STREAM_CONFIG`: HDR uygulanınca 9/16/9/0, değilse bugünkü SDR kodları.
- Geri dönüş: ekran tf=1 reddi, SCK HDR hatası, VT Main10/PQ reddi → SDR yoluna dön, `ev=hdr_fallback reason=`, STREAM_CONFIG SDR kodları. `ev=hdr_config requested= applied= …` her yapılandırmada.
- `MATEBRIDGE_VD_TRANSFER` geliştirici anahtarı kalır (SDR akışla HDR ekran), `dynamic_range=1` onu gerektirmez.
- Pencere açma, çalışan host'a ve tablete dokunma. Cihaz kabulünü orkestratör yapar.

## Kabul kriterleri

- [ ] [XCTest] Üç yeni fixture decode/encode ve hata; eski fixture'lar değişmez; `dynamic_range` bilinmeyen değer → 0.
- [ ] [XCTest] Politika: istek + yetenek → HDR yapılandırması; her geri dönüş nedeni → SDR + doğru `reason`; `dynamic_range` değişimi yeni `config_id` ve ekran yeniden kurma kararı; hatırlanan tercih `dynamic_range`'i taşır.
- [ ] Varsayılan (SDR) yol bit-bit aynı.
- [ ] `ev=hdr_config`, `ev=hdr_fallback` docs/LOGGING.md'de.
- [ ] `./scripts/check.sh` geçer (istemci tarafı fixture testleri T-238'de; bu dalda Android fixture testleri yeni dosyalar için düşebilir — yalnız host kısmının geçtiğini Handoff'a yaz).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
