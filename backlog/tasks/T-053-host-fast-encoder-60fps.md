---
id: T-053
title: Mac — hızlı kodlayıcı yapılandırması (LLRC'siz, RealTime=false) 60 fps'te de: gecikmeyi düşür
status: done
phase: 5
owner: mac-host-dev
depends_on: [T-047, T-049]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-053-host-fast-encoder-60fps.md
---

## Amaç

T-047: 2800×1840'ta LLRC'siz + `RealTime=false` yapılandırması kare başına kodlamayı ~9–13 ms'den ~6 ms'ye indiriyor; bugün yalnızca fps ≥ 120'de kullanılıyor. 60 fps modunda (Netlik) canlı ölçümde kodlama 13,5 ms. Kullanıcı gecikmeyi en aza indirmek istiyor.

## Kabul kriterleri

- [ ] `--encode-bench` ile 60 fps (tempolu) iki yapılandırma karşılaştırılır: bugünkü (LLRC) ve hızlı; p50/p95/p99 kodlama süresi, bit hızı, **kare boyutu dağılımı** (p50/p99/en büyük; anahtar kareler ayrı) — LLRC'nin sağladığı kare boyutu düzgünlüğü kaybolursa Wi-Fi'de sıçrama riski. Tablo Handoff'ta.
- [ ] Hızlı yapılandırma kare boyutunu makul tutuyorsa (öneri: p99 kare ≤ ortalamanın 4 katı, anahtar kare hariç) tüm fps'lerde varsayılan olur; değilse yalnızca USB taşımada (host oturumun taşımasını biliyor: T-039 `SessionTransport`). Kararın gerekçesi Handoff'ta.
- [ ] `MATEBRIDGE_ENCODER=llrc|fast` ortam değişkeni karşılaştırma için.
- [ ] `./scripts/check.sh` geçiyor.

## Kapsam dışı

- Tablet. Canlı ölçüm orkestratörde.

## Plan

1. Core: `EncoderProfile` (llrc|fast, `MATEBRIDGE_ENCODER` ayrıştırma + çözümleme), `FrameSizeStats` (anahtar/delta kare boyutu), bench `--content scroll|patch` ve `llrc`/`fast` katalog girdileri; testler.
2. Bench: kare boyutu dağılımı, havuzda ping-pong (sarma sıçraması yapay p99 üretiyordu).
3. `--fps 60` ile llrc vs fast tekrarlı ölç; karar; `HEVCEncoder` profile göre.

## Handoff

- **Commit:** (orkestratöre raporlandı)
- **Dokunulan dosyalar:** Core: `Video/EncoderProfile.swift`, `Video/FrameSizeStats.swift`, `Video/EncodeBench.swift` (+catalog `llrc`/`fast`, `--content`); Host: `Video/HEVCEncoder.swift`, `Video/EncodeBench.swift`; Tests: `Video/EncoderProfileTests.swift`; bu kart.
- **Sonuçlar** (`--fps 60 --seconds 6`, paced 60, in-flight 2, her config ayrı süreç; canlı oturum açıkken; `--content scroll` 3 tekrar, ilk ölçümde 4 tekrar):

| içerik | config | enc ms p50/p95/p99 | Mbps | delta KB p50/p99/max (ort, p99/ort) | anahtar KB |
|---|---|---|---|---|---|
| scroll | llrc | 9.2-9.6 / 9.5-10.4 / 10.1-10.5 | 29.6 | 60/73/99 (59, 1.23x) | 960 |
| scroll | fast | 6.3-6.4 / 6.7-8.3 / 6.9-9.4 | 29.9 | 60/92/96 (60, 1.54x) | 1000 |
| patch | llrc | 9.0-9.2 / 9.5-10.5 / 10.4-13.4 | 1.9 | 1/23/40 (1, -) | 953 |
| patch | fast | 5.6-5.9 / 6.4-6.9 / 7.8-8.5 | 4.1 | 1/153/189 (6, -) | 993 |

  Yayılım küçük: kare boyutları çalıştırmalar arası deterministik (aynı), süre p50 ±0.3 ms. (İlk sürümde havuz sarma sıçraması p99/ort 6.9-7.7x gibi yapay değer veriyordu; ping-pong ile giderildi.)
- **Karar:** hareketli içerikte fast p99/ort 1.54x (<= 4x) ve bit hızı aynı -> **fast tüm fps'lerde varsayılan** (taşıma ayrımı gerekmedi), kodlama ~9.4 -> ~6.2 ms. `MATEBRIDGE_ENCODER=llrc|fast` geçersiz kılar. Uyarı: neredeyse statik içerikte (patch) oran anlamsız (ort ~1 KB), fast'te seyrek 150-190 KB kareler (llrc: en çok 40 KB) ve ~2x bit hızı var; tek kare 190 KB = Wi-Fi'de birkaç ms, kabul edilebilir ama canlıda (kalem çizimi, statik ekran) sıçrama/ bit hızı gözlenmeli; sorun çıkarsa `MATEBRIDGE_ENCODER=llrc`.
- **Varsayımlar:** sentetik içerik; gerçek ekran farklı olabilir. `MATEBRIDGE_ENCODER` 120 fps'te `llrc` verilirse LLRC kullanılır (tavan ~100 fps).
- **Test edilmeyenler / cihazda doğrulanacaklar:** canlı: 60 fps'te kodlama ~6 ms, `enc_behind`, statik/kalem içerikte kare boyutu sıçramaları ve Wi-Fi'de takılma, keyframe-on-demand/drop sonrası kurtarma (fast yolunda), bit hızı hedefi (DataRateLimits). Uygulama çalıştırılmadı.
- **Açık sorular:** yok.

## Orkestratör notu (merge, 2026-10-01)

- Kodlayıcı ayarı; Codex turu yapılmadı (girdi/güvenlik dışı). Canlı: Performans modunda kodlama ~7 ms, `enc_behind=0`. Wi-Fi'de durağan içerikte ara ara 150–190 KB kareler olası; sorun görülürse `MATEBRIDGE_ENCODER=llrc`.
