---
id: T-143
title: "Oyun 60" modunu ekle, mevcut Oyun modunu "Oyun 120" olarak adlandır
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
