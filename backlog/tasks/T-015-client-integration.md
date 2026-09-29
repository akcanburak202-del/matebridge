---
id: T-015
title: Android entegrasyonu — oturum + görüntü, tam ekran, istatistik katmanı
status: todo
phase: 1
owner: android-client-dev
depends_on: [T-012, T-013]
decisions: [0004]
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
---

## Amaç

Bağlı oturumda video bağlantısındaki kareleri tam ekran göstermek, STATS göndermek ve ekran üstü istatistik katmanı sunmak.

## Kabul kriterleri

- [ ] Bağlanınca tam ekran, immersive, yatay, ekran açık kalır. Video yüzeyi ↔ normalize koordinat dönüşümü tek yerde (siyah bant dahil, PROTOCOL.md §1).
- [ ] Saat farkı tahmini (§6) ve `STATS` her 1 sn.
- [ ] İstatistik katmanı (aç/kapa): FPS, bitrate, çözme süresi, tahmini gecikme, atılan kare.
- [ ] Arka plana geçince video durur, geri gelince keyframe istenir. Bağlantı yoksa "Bağlantı yok" ekranı.
- [ ] `./scripts/check.sh` geçiyor.

## Plan

_(Ajan doldurur.)_

## Handoff

- **Commit:**
- **Dokunulan dosyalar:**
- **Varsayımlar:**
- **Test edilmeyenler / cihazda doğrulanacaklar:**
- **Açık sorular:**
