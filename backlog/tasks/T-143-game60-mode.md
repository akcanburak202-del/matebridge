---
id: T-143
title: "Oyun 60" modunu ekle, mevcut Oyun modunu "Oyun 120" olarak adlandır
status: done
phase: 5
owner: android-client-dev
depends_on: [T-109]
decisions: [0014, 0016]
files:
  - client-android/app/src/
  - backlog/tasks/T-143-game60-mode.md
---

## Amaç

Karar 0016: Panel dokunma olmadan 60 Hz'de kaldığı için klavye ya da gamepad oyunlarında Oyun modu fiilen 60 fps veriyor, üstelik %66 bulanıklıkla. Yeni "Oyun 60" modu (60 fps, %100) aynı düşük gecikme davranışlarını tam çözünürlükte sunar. Mevcut mod "Oyun 120" adını alır.

## Kapsam dışı

- Protokol, host. Modun otomatik seçimi. Performans modu (kalıyor).

## Kabul kriterleri

- [ ] `StreamMode`: `GAME` etiketi "Oyun 120" (id `game`, 120 fps, 660 değişmez). Yeni `GAME60` ("Oyun 60", id `game60`, 60 fps, 1000). Sıra: Netlik → Akıcı → Performans → Oyun 120 → Oyun 60 (döngü ve panel listeleri).
- [ ] Oyun 60, karar 0014'ün bütün oyun davranışlarını paylaşır: jitter 0, `GameModeSettings` geçici varsayılanları, oturum katmanı kuralları, paneldeki "(oyun modu)" işareti, kayıtlı mod Oyun 60 ise açılışta katmanın kurulması. Koddaki `mode == GAME` kontrollerinin tamamı "oyun modlarından biri" anlamına gelecek şekilde güncellenir (ör. `StreamMode.isGame`). Atlanan yer kalmamalı, Plan'da liste olarak verilir.
- [ ] Oyun 120 ↔ Oyun 60 geçişi oyun modundan çıkış sayılmaz: o oyun oturumundaki geçici değişiklikler korunur. Oyun dışı bir moda geçince katman bugünkü gibi düşer.
- [ ] Bildirim ve buton metinleri yeni adlarla ("Oyun 120: 120 fps, %66", "Oyun 60: 60 fps, %100").
- [ ] JVM testleri: döngü sırası, `parse("game60")`, bilinmeyen id → varsayılan, Oyun 120 ↔ 60 geçişinde katmanın korunması, oyun dışı moda geçişte düşmesi, Oyun 60'ta jitter 0.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

1. `StreamMode`: `GAME` etiketi "Oyun 120"; yeni `GAME60("game60","Oyun 60",60,1000)` en sona; `val isGame` (GAME veya GAME60). Döngü/panel `entries` sırasından geldiği için sıra otomatik doğru.
2. Değişen oyun-modu kontrolleri (tam liste; kodda `GAME` referansı tarandı):
   - `GameMode.kt` `GameModeSettings.onModeChanged`: `mode == StreamMode.GAME` -> `mode.isGame` (tek gerçek kontrol; Oyun120<->Oyun60 `null` döner, katman korunur).
   - Diğer yerler (`MainActivity` açılışta `onModeChanged`, `currentJitter` -> `GameJitter.choose(..., gameSettings.active)`, `SettingsCatalog` işareti `gameDefaultsActive`, `prefs(mode)`) `mode == GAME` kullanmıyor, `gameSettings.active`'e bağlı; kod değişikliği gerekmez. KDoc yorumları güncellenir.
3. Metinler `label`/`toastText` üzerinden gelir; ayrı sabit yok.
4. Testler: StreamModeTest, GameModeTest, SettingsCatalogTest güncellenir/eklenir (döngü sırası, parse game60, bilinmeyen id, 120<->60 katman korunur, oyun dışına geçişte düşer, Oyun 60 jitter 0, açılışta kayıtlı game60).

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:** stream/StreamMode.kt, stream/GameMode.kt (main); StreamModeTest, GameModeTest, SettingsCatalogTest (test); bu kart.
- **Varsayımlar:** Tek gerçek `== GAME` kontrolü GameModeSettings.onModeChanged idi; gerisi `gameSettings.active`'e bağlı, MainActivity değişmedi.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Ctrl+Shift+7 döngüsü Netlik>Akıcı>Performans>Oyun 120>Oyun 60>Netlik; Oyun 60 60 fps/%100 ve panelde "(oyun modu)"; Oyun 120<->60 geçişinde geçici ayarlar korunur; kayıtlı mod Oyun 60 ile açılışta katman kurulur.
- **Açık sorular:** yok
