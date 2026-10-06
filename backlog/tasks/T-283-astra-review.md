---
id: T-283
title: Review — gpt-6-astra (high), 2026-10-04 değerlendirmesinden bu yana + riskli dört bölge
status: in-progress
phase: 6
owner: orchestrator
depends_on: [T-282]
decisions: []
files:
  - docs/reviews/
  - docs/NOTES.md
  - backlog/tasks/T-283-astra-review.md
---

## Amaç

Kullanıcı onayı (2026-10-06): Codex `gpt-6-astra`, `model_reasoning_effort=high`, salt okunur, kapsamı daraltılmış kod incelemesi. Önceki genel değerlendirme: `docs/reviews/2026-10-04/astra-assessment.md` (`main` @ `0d796e8`). Odak: doğruluk ve gereksiz karmaşıklık. Performans T-282'de.

## Kapsam

1. `0d796e8..main` arası değişiklikler. HDR10 (0032), Keskin renk / Tam renk 4:4:4 (0033/0034), Wi-Fi dosyaları (0035), yerel imleç ve tahmin (0036), sessizlik kapısı, modlar ve oyun ekranı.
2. Hata maliyeti yüksek dört bölge (değişmemiş olsa da):
   - **girdi durumu:** takılı tuş/düğme/kalem, release yolları (`InputStateMachine`, `InputCapture`/`InputOutbox`, kopma/arka plan);
   - **oturum ve yeniden bağlanma:** `SessionMachine`, `VideoHealth`, host `StreamCoordinator`, uyku/uyanma;
   - **kuyruklar:** video (en yeni kazanır), ses halkası, dosya, sınırlılık;
   - **özel API sınırı:** `VirtualDisplay`.
3. 2026-10-04 bulgularının (T-218, T-219 …) düzeltmelerinin gerçekten kapandığını doğrula.

## Kabul

1. Çalıştırma: `codex exec -m gpt-6-astra -s read-only -c 'model_reasoning_effort="high"'` ile özel istem (`scripts/codex-review.sh` model sabitli, kullanma). İstem bu kartın Kapsam'ını, AGENTS.md hard rules'u ve önceki raporun yolunu içerir. Bulguları P1/P2/P3, dosya:satır ve somut senaryo ile istersin.
2. Çıktı değiştirilmeden `docs/reviews/2026-10-07/astra-review.md`'ye yazılır. Orkestratör üstüne kısa bir triyaj notu ekler.
3. Her P1/P2 bulgusu doğrulanır: kod okunur, gerekirse test yazılır. Gerçekse kart açılır, değilse gerekçesiyle "değil" denir.
4. Onay yalnız bu çalıştırmayı kapsar (başarısız olursa bir kez yeniden). Başka astra kullanımları için yeniden sorulur.

## Plan

- İstem scratch'te (`astra-prompt.txt`), `main` @ T-282 sonrası sabit SHA. `codex exec -m gpt-6-astra -s read-only -c 'model_reasoning_effort="high"' -o <scratch>/astra-out.md`, arka planda.
- Çıktı aynen `docs/reviews/2026-10-07/astra-review.md`'ye, üstüne triyaj. P1/P2 doğrulaması okuma ajanlarıyla (paralel), gerçekse kart.

## Handoff

## Open questions
