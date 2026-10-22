---
id: T-363
title: Host — gizli imleç: Terminal "yazarken gizle" T-361 ile açılmıyor; yerinde + kaydırılmış iki olay
status: in_progress
phase: 7
owner: mac-host-dev
depends_on: [T-361]
decisions: []
files:
  - host-mac/Sources/MateBridgeCore/Input/
  - host-mac/Sources/MateBridgeHost/Input/
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - backlog/tasks/T-363-hidden-cursor-unobscure.md
---

## Amaç

T-361 kurulduktan sonra (2026-10-22 23:50) geriye gidiş: Terminal'de yazınca gizlenen imleç trackpad hareketiyle **geri gelmiyor**, ancak tıklamayla geliyor. T-361 öncesi sorunsuzdu.

Kanıt (canlı izleme, `CGCursorIsVisible` + konum her 20 ms, 2026-10-22 23:54–23:56):
- Gizliyken konum gerçekten değişiyor (ör. 581,722 → 605,594 → … → 133,863; alt kenarda y=910.5, yani 8 pt iç sınır), `visible=0` kalıyor; `visible=1` yalnız tıklamada.
- Host: `pointer_hidden_mode state=on` sonra saniyelerce `pointer_hidden_n` > 0, `off` ancak tıklamada.
- T-361 öncesi: gizli modda gönderilen `mouseMoved` konumu **değiştirmiyordu** (yalnız delta). Terminal'in gizlemesi (AppKit `setHiddenUntilMouseMoves` / obscure) bu olayla anında açılıyordu (log'da 16 ms'lik on/off).
- Öte yandan web sayfası gizlemesi (YouTube, CSS `cursor: none`) yalnız gerçek konum değişimiyle açılıyor (T-361 kanıtı: +1 pt `mouseMoved` imleci gösterdi).
- Çıkarım (doğrulanmadı, cihaz testi gerekecek): obscure'u açan, konumu değiştirmeyen (warp sayılmayan) delta'lı hareket olayı; konumu değiştiren olay onu açmıyor.

## Kabul

1. İmleç gizliyken her `POINTER_REL` **iki** olay üretir, sırayla:
   a. Taban konumda (canlı imleç, T-272 gibi), delta'lı `mouseMoved`/`…Dragged` — T-361 öncesi olay; Terminal obscure'unu açar. Oyunlar deltayı bu olaydan okur.
   b. T-361 hedefinde (8 pt iç sınır, duvarda 1 pt içeri adım), **delta 0** — konumu değiştirir; web sayfalarını uyandırır.
   Delta toplamı tek olay gibi kalır (kesir taşıma aynı), ikinci olay deltası 0.
2. Görünürken davranış aynen (tek olay).
3. Düğme basılıyken (sürükleme) aynı iki olay, ikisi de `…Dragged`. Down/up kaybolmaz, sırası değişmez.
4. `hiddenCursorMoves` sayacı mesaj başına 1 artar (olay başına değil). `remember` yalnız b hedefi için.
5. `POINTER_ABS`, kalem, dokunma, kaydırma değişmez.
6. Testler: gizli hareket iki olay üretir (a konumu = taban, a delta = hareket; b konumu = iç sınırlı hedef, b delta = 0), gizli sürükleme iki dragged, görünür tek olay, kesir taşıma. Mevcut HID testleri yeni olay sayısına göre güncellenir (Handoff'ta liste).
7. LOGGING.md'deki gizli imleç cümlesi güncellenir.

## Plan

## Handoff

## Open questions
