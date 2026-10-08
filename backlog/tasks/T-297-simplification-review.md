---
id: T-297
title: Sadeleştirme incelemesi — alt sistem başına Opus ajanları + gpt-6-astra (high) mimari geçiş + gpt-6.1-sol doğrulama
status: in-progress
phase: 7
owner: orchestrator
depends_on: []
decisions: []
files:
  - docs/reviews/2026-10-08/
  - backlog/tasks/T-297-simplification-review.md
---

## Amaç

Kod ~67 bin satır ürün, ~64 bin satır test. Davranışı değiştirmeden şunları kaldırmak ya da birleştirmek:
- ölü ve yalnız testte kullanılan kod;
- iki katta yapılan işler;
- gereksiz soyutlamalar;
- deneme sonrası kalan anahtarlar ve yollar;
- iki tarafın aynı kavramı farklı adlandırması.

Kullanıcı onayı 2026-10-08, astra dahil (tek çalıştırma, bir yeniden deneme).

## Yöntem

1. **Salt okuma Opus 5.5 ajanları, paralel**, her biri bir alt sistem:
   - (a) host video: yakalama, kodlama, Metal, gönderici;
   - (b) host oturum, girdi, güç, ekran ömrü, menü;
   - (c) istemci video, gösterim, zamanlayıcı, renk yolları;
   - (d) istemci oturum, ağ, ses, dosyalar, imleç;
   - (e) iki taraftaki protokol ve şifreleme kodu, test yardımcıları;
   - (f) geliştirici anahtarları (`docs/KNOBS.md`) ve deney artıkları.
2. **gpt-6-astra (high), salt okuma, bütün depo, `main` @ `1eba3d3e`:** katmanlar arası birleştirme ve yapısal performans sorunları. Çıktı değiştirilmeden `docs/reviews/2026-10-08/astra-simplification.md`'ye yazılır.
3. **Doğrulama:** kısa listedeki her madde için kod okunur. Kaldırma ya da birleştirmenin davranışı değiştirmediği gösterilir. Gerekirse gpt-6.1-sol ikinci görüş verir.
4. **Rapor:** `docs/reviews/2026-10-08/simplification.md`. Her madde için:
   - etki (satır, karmaşıklık, sıcak yol mu);
   - risk;
   - dokunduğu dosyalar;
   - T-298 bulgularıyla çakışma.

## Kabul

1. Rapor ve triyaj yazılır. Uygulama kartları T-298 ile ortak ayıklamadan sonra açılır.
2. Girdi güvenliği, protokol ve özel API kuralları (AGENTS.md) gevşetilmez. Bunları zayıflatan bir öneri "reddedildi" diye kaydedilir.

## Plan

## Handoff

## Open questions
