---
id: T-309
title: Host — yerel imleç örnekleyicisi her girdi olayında imleç görüntüsünü kopyalayıp hash'liyor; biçim kontrolü yalnız imleç değiştiğinde
status: review
phase: 7
owner: mac-host-dev
depends_on: []
decisions: [0036]
files:
  - host-mac/Sources/MateBridgeHost/Cursor/
  - host-mac/Sources/MateBridgeCore/Cursor/
  - host-mac/Tests/MateBridgeCoreTests/Cursor/
  - docs/LOGGING.md (orchestrator)
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

1. Core: `CursorShapeCheckGate` (hız sınırlayıcı, 66 ms = ~15 Hz; gizli->görünür geçişte ve şekil yokken zorunlu kontrol).
2. `CursorSampler.sample()`: konum + görünürlük her seferinde; `currentShapeID` (NSCursor kopyası, render, pixelHash) yalnız kapı izin verince. `pixelHash` yalnız `currentShapeID` içinde olduğundan yalnız kontrol anında çalışır.
3. `CursorStats`: `shape_checks=`. Testler: kapı + güncellenen stats satırı.

## Handoff

- Branch `task/T-309-cursor-sampler`; commit SHA: `git log -1` (bu kartı içeren commit).
- Dosyalar: `Core/Cursor/CursorShapeCheckGate.swift` (yeni), `Core/Cursor/CursorStats.swift`, `Host/Cursor/CursorSampler.swift`, `Host/Cursor/CursorService.swift`, `Tests/.../Cursor/CursorShapeCheckGateTests.swift` (yeni), `CursorPlannerTests.swift` (stats satırı), bu kart.
- **Seçilen yol: oran sınırı (66 ms, ~15 Hz); seed sayacı kullanılmadı.** Gerekçe: `CGSCurrentCursorSeed` özel/belgesiz SkyLight sembolü; güvenilirliği (WindowServer yeniden başlayınca, uygulama özel imleç ayarlarken sayacın artması) donanımsız doğrulanamadı; oran sınırı genel API ile aynı kazancı verir (360 -> ~15 kontrol/s) ve kartın "güvenilmezse" dalıdır. Seed ileride aynı kapının önüne eklenebilir. Bu yüzden Core'da ayrı seed karşılaştırma mantığı yok.
- Davranış: konum/görünürlük her örnekte; şekil ilk örnekte, her 66 ms'de bir ve gizli->görünür geçişinde (aralık içinde bile) okunur; oturum başında kapı sıfırlanır. Şekil değişimi en çok 66 ms gecikir (<=70 ms). Gizliyken şekil okunmaz (önceki gibi). Yeni şekil -> CURSOR_SHAPE gönderimi değişmedi.
- Log: `cursor_stats` içine `shape_checks=<n>` (`shape_failed`'den sonra, `replaced`'dan önce). Önerilen docs/LOGGING.md ekleme (kart kapsamı dışı, orkestratör eklesin): `shape_checks`: bu pencerede imleç görüntüsü okunup şekil kimliği hesaplanan kontrol sayısı (oran sınırlı, en çok ~15/s; `samples` ile karşılaştır).
- check.sh: ALL OK.
- Cihazda doğrulanmadı: T-305 sentetik kalem kolu ve gerçek çizimle imleç kuyruğu/host CPU önce-sonra; ok -> metin imleci değişiminin tablete ~70 ms içinde gittiği; `shape_checks` ~15/s.

## Open questions

- docs/LOGGING.md `cursor_stats` satırı güncellenmeli (dosya kartın `files:` listesinde değil).
- İsteğe bağlı: seed sayacı (SkyLight) ayrı kartta denenebilir; ölçümden sonra gerek kalmayabilir.

## Review round 1 (Codex P2 x2)

- Aralik 66 -> 57 ms: kontrol yalniz ornekte yapildigindan en kotu gecikme aralik + 1 zamanlayici periyodu (8,33 ms) = 65,3 ms (<= 70). Test: kontrol 2 ms'de, degisim 2,1 ms'de.
- Hiz siniri artik `hasShape` false iken de gecerli (ilk deneme zorunlu, sonraki basarisiz denemeler ayni aralikla): bozuk render/PNG 360 Hz'de sicak noktayi geri getirmez. Test eklendi. Gizli->gorunur gecis hala zorunlu kontrol.
- docs/LOGGING.md `cursor_stats` satirina `shape_checks` eklendi (orkestratör izniyle); `~17/s`.
