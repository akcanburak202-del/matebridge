---
id: T-053
title: Mac — hızlı kodlayıcı yapılandırması (LLRC'siz, RealTime=false) 60 fps'te de: gecikmeyi düşür
status: todo
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

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
