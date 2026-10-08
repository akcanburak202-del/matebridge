---
id: T-298
title: Optimizasyon araştırması — gecikme zinciri, kodlayıcı/yakalama ayarları, tablet enerji/CPU, ağ
status: done
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/research/2026-10-08-optimization.md
  - backlog/tasks/T-298-optimization-research.md
---

## Amaç

Kullanıcı 2026-10-08'de optimizasyona derinlemesine girmek istedi. Önceki tur `docs/research/2026-10-07-perf-profile.md` (T-282, T-284..T-292). Bu kart, ölçüme bağlanabilir yeni fırsatları kod ve kaynak araştırmasıyla bulur. Uygulama kartları T-297 ile ortak ayıklamadan sonra açılır ve her biri T-296 tabanına karşı A/B ölçülür.

## Yöntem

Salt okuma Opus 5.5 ajanları, paralel:
- **(a) Host gecikme ve verim:**
  - SCK yapılandırması: kuyruk derinliği, piksel biçimi, dönüşümler;
  - VT ayarları: düşük gecikme kipi, slice, referans, QP ve hız denetimi, keyframe boyutu;
  - Metal geçişlerinin maliyeti; kopyasız yol;
  - gönderici ve soket: paketleme ve patlama yumuşatma.
- **(b) İstemci gecikme ve enerji:**
  - MediaCodec düşük gecikme ve HiSilicon anahtarları (`docs/research/2026-10-04-smoothness.md`);
  - gösterim yolu: SurfaceView, zamanlama, 120 Hz;
  - "Tam renk" GL birleştirme maliyeti;
  - iş parçacığı ve uyanma bütçesi; DVFS.
- **(c) Uçtan uca ve ağ:**
  - gecikme zincirinin tek saatle dökümü: hangi loglar var, ne eksik;
  - ekrandan ekrana ölçüm yöntemi (T-174);
  - Wi-Fi dalgalanması ve bit hızı uyarlaması;
  - ses ve görüntü eşzamanlaması;
  - pil ve ısı.

Her bulgu şunları içerir: kanıt (dosya:satır ya da kaynak bağlantısı), beklenen kazanç ve nasıl ölçüleceği, risk, T-297 ile çakışma.

## Kabul

1. `docs/research/2026-10-08-optimization.md`: bulgular kazanç/maliyet sırasıyla; "ölçüm gerekiyor" ve "hemen yapılabilir" ayrı listelenir.

## Plan

## Handoff

2026-10-08: `docs/research/2026-10-08-optimization.md` ve ajan özetleri `docs/reviews/2026-10-08/agents/opt-*.md`. Sıralama `simplification.md` içinde.

## Open questions
