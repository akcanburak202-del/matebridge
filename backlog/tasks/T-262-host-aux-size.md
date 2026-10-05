---
id: T-262
title: Host — shrink the full-chroma auxiliary stream (aux bytes are 1.25–1.5× main instead of ~0.4×)
status: ready
phase: 6
owner: mac-host-dev
depends_on: [T-258]
decisions: [0034]
files:
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Tests/
  - probes/yuv444-probe/
  - docs/LOGGING.md
  - backlog/tasks/T-262-host-aux-size.md
---

## Amaç

İlk cihaz testinde host `ev=chroma_stats aux_main_bytes` 1,23–1,50 (NOTES 2026-10-06 ~00:35); tasarım/T-255 M3 ~0,3–0,45 bekliyordu. Büyük yardımcı kare Wi-Fi'da geç geliyor (titreme nedeninin bir parçası, T-261 istemci tarafını çözüyor) ve toplam bant ~2,2–2,5×. Yardımcıyı küçült, ama kaliteyi koru.

## Bağlam

- Önce **neden**: yardımcı oturumun `AverageBitRate`/`DataRateLimits`'i (ana hedefin %50'si) etkili mi (`PackedAuxEncoder.swift` ~86, ~153; T-258 Codex düzeltmesiyle sıralı uygulanıyor)? Yardımcı içerik (Cb/Cr örneklerinin luma gibi paketlenmesi) kodlayıcı için "gürültülü" mü; T-253 netleştirme trenleri iki akışta da çalışırken yardımcı payı mı şişiriyor? `aux_main_bytes`'ı hareketli / durağan / netleştirme için ayrı ölç (log alanı ekle).
- Seçenekler (ölçerek seç, `probes/yuv444-probe` encode-bench / quality ile Mac'te, pencere açmadan): yardımcıya daha düşük kalite/ hedef (ör. ana %25–35), yardımcıda netleştirme trenini kısıtlama ya da kapama, yardımcının IDR aralığı, `MaxFrameDelayCount`/`MaxAllowedFrameQP` gibi VT ayarları. Kalite ölçütü: T-255 M3 RGB PSNR ve renkli yazı kırpıntıları (tam renk 4:2:0'dan belirgin iyi kalmalı; hedef ≥ 41 dB yapay sahnede).
- Tel biçimi ve istemci değişmez.

## Kabul kriterleri

- [ ] Ölçüm tablosu (önce/sonra: aux/main bayt oranı hareketli/durağan, PSNR) Handoff'ta; seçilen ayarın gerekçesi.
- [ ] `./scripts/check.sh` geçer; birim testleri değişen politika için.
- [ ] Handoff: cihaz doğrulama adımları (`aux_main_bytes`, `aux_paired_pct` istemcide).

## Plan

## Handoff

## Open questions
