---
id: T-309
title: Host — yerel imleç örnekleyicisi her girdi olayında imleç görüntüsünü kopyalayıp hash'liyor; biçim kontrolü yalnız imleç değiştiğinde
status: todo
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0036]
files:
  - host-mac/Sources/MateBridgeHost/Cursor/
  - host-mac/Sources/MateBridgeCore/Cursor/
  - host-mac/Tests/MateBridgeCoreTests/Cursor/
  - backlog/tasks/T-309-host-cursor-sampler-cost.md
---

## Amaç

T-305 (`docs/research/2026-10-08-pen-path.md`, Bulgu 1). Gerçek M-Pencil (360 örnek/s) ile çizerken `dev.matebridge.cursor` kuyruğu tek çekirdeğin ~%57'sini kullanıyor (debug host). Sentetik kalemde release host'ta da ~%62. Yol:
- `CursorService.noteInjected()` (~:149) → `takeSample()` (~:237) → `CursorSampler.sample()` (~:75) → `currentShapeID(nowNs:)` (~:82/94);
- burada `+[NSCursor currentSystemCursor]` (WindowServer'dan görüntü kopyası: `SLSCopyRegisteredCursorImages`, `CGBlt`), `CursorSampler.render` (`CGContextDrawImage`) ve `CursorShapeLayout.pixelHash` çalışıyor.

Bu, her girdi olayında ve 120 Hz zamanlayıcıda tekrarlanıyor. Biçim nadiren değişiyor.

## Kabul

1. **Konum ve biçim ayrılır.** Girdi olayıyla tetiklenen örnek yalnız konumu ve görünürlüğü okur (ucuz yol).
2. **Biçim kimliği yalnız gerektiğinde yeniden hesaplanır.**
   - Önce imleç "seed" sayacı denenir (SkyLight/CGS seed ya da eşdeğer genel API). Bulunamazsa ya da güvenilmezse biçim kontrolü en çok ~15 Hz ile sınırlanır; biçim değişiminden sonraki ilk kontrol ≤ 70 ms gecikir.
   - Hangi yolun seçildiği ve gerekçesi Handoff'a.
   - Özel API kullanılırsa tek bir yerde yalıtılır ve yoksa genel yola düşer. Yeni bağımlılık yok.
3. **`pixelHash`** yalnız gerçekten yeni bir görüntüde çalışır.
4. **Davranış 0036 ile aynı kalır.** Biçim değişince tablete `CURSOR_SHAPE` gider; konum akışı ve gizleme kuralları değişmez.
5. **Saf kısımlar Core'da test edilir:** hız sınırlayıcı ve seed karşılaştırma mantığı.
6. **Log:** `cursor_stats` alanlarına biçim kontrolü sayısı eklenir (ör. `shape_checks=`). Önerilen LOGGING metni Handoff'a.
7. **Cihazda bakılacak (orkestratör):** T-305 sentetik kalem kolu ve gerçek çizim tekrarlanır; imleç kuyruğu ve host CPU önce/sonra karşılaştırılır.

## Plan

## Handoff

## Open questions
