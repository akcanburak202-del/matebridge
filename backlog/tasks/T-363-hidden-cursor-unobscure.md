---
id: T-363
title: Host — gizli imleç: Terminal "yazarken gizle" T-361 ile açılmıyor; yerinde + kaydırılmış iki olay
status: done
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

`InjectionPlanner.mouseMove`, `.relative where env.cursorHidden` dalı: hedef/delta hesabı aynı (T-361 hedefi, ham delta, kesir taşıma); `hiddenFirst = base` işaretlenir ve olay üretiminde iki olay çıkar: (a) base konumunda delta'lı, (b) hedefte delta 0; ikisi de aynı kind (moved/dragged). `cursor = target`, `remember` yalnız hedef için, sayaç mesaj başına. Testler `pair(...)` yardımcısıyla güncellenir; LOGGING.md cümlesi.

## Handoff

- Commit: son `T-363: ...` commit'i (branch `task/T-363-hidden-cursor-unobscure`).
- Dosyalar: `host-mac/Sources/MateBridgeCore/Input/InjectionPlanner.swift`, `host-mac/Tests/MateBridgeCoreTests/Input/HiddenCursorTests.swift`, `docs/LOGGING.md`, bu kart. `MateBridgeHost` değişmedi.
- Davranış: gizliyken her `POINTER_REL` iki olay (a: base, delta; b: T-361 hedefi, delta 0), sürüklemede ikisi de `dragged`. Görünür/ABS/kalem/dokunma/kaydırma/düğme değişmedi.
- Değişen test beklentileri (hepsi HiddenCursorTests, tek olay yerine iki olay): HID-1, 1b (köşe tabloları + tekrarlı itme son olaydan okunur), 1c, 1d, 3 (delta ilk olayda, ikincisi 0; konum ikinciden), 4 (iki dragged, a delta -25, b 0), 5 (son olaydan okunur), 6. Yeni: HID-1e (duvara itme çifti, sayaç mesaj başına). HID-2/2b/7/8/9 ve diğer paketler (fuzz/pipeline dahil) değişmedi.
- check.sh: ALL OK (1299 test).
- Gerçek donanımda EDİLMEDİ (CGEvent gönderilmedi): Terminal'de yazınca gizlenen imleç trackpad hareketiyle geri geliyor mu (kartın çıkarımı doğrulanmadı); Safari/YouTube gizli imleç hâlâ geri geliyor mu; oyunda (delta okuyan) çift olay çift hareket saymıyor mu (ikinci delta 0 olduğundan saymamalı).

## Open questions
