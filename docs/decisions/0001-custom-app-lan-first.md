# 0001 — Hazır çözüm yerine özel uygulama, önce yerel ağ

- **Durum:** kabul
- **Tarih:** 2026-09-29

## Bağlam
Parsec, Jump Desktop, Duet ve Moonlight/Sunshine incelendi. Hiçbiri Android'den (M-Pencil) Mac'e basınç ve eğimi tasarım/çizim kalitesinde taşımıyor. Parsec'te Mac host için 4:4:4 yok, Jump Desktop ücretli. Kullanıcının önceliği ev ağında OLED ekranı iyi kullanan net görüntü, basınçlı kalem ve klavye/trackpad.

## Karar
MateBridge özel olarak yazılır. Birincil taşıma yerel ağ (Wi-Fi). USB (`adb reverse`) aynı kodla gelen yedek mod. İnternet erişimi kapsam dışı.

## Sonuçlar
- Kalem basıncı ve eğimi çekirdek özellik, Aşama 2'de.
- Wi-Fi gecikme sıçramaları bir risk. Video kanalı için TCP ve UDP Aşama 1'de ölçülerek seçilir.
- Ev ağında bile yetkisiz girdi enjeksiyonu riski var. Mac tarafında bağlantı onayı Aşama 1'den itibaren zorunlu.
