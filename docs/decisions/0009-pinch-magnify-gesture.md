# 0009 — İki parmakla yakınlaştırma: PINCH mesajı ve belgelenmemiş büyütme olayı

- **Durum:** kabul
- **Tarih:** 2026-09-30

## Bağlam
Kullanıcı dokunmatik ekranda iki parmakla yakınlaştırma istedi (PLAN Aşama 3). macOS'ta trackpad büyütme hareketi üreten genel bir CGEvent API'si yok. Mac Mouse Fix, CGEvent'in belgelenmemiş alanlarıyla bir hareket olayı üretiyor (tip 29 `NSEventTypeGesture`, alan 110 = 8 zoom, alan 132 = faz, alan 113 = büyütme). macOS 27'de alan tabanlı dock kaydırmaları bozulmuş, ama büyütme bu Mac'te denendi ve çalıştı: Krita 5.3.4'te %176 → %452 (NOTES 2026-09-30).

## Karar
1. Protokole `0x17 PINCH` eklenir (PROTOCOL §4): faz, göreli ölçek değişimi, normalize merkez, kaynak (dokunmatik ekran / touchpad). Tablet iki parmak hareketini ya kaydırma ya yakınlaştırma olarak sınıflar; hareket boyunca değişmez.
2. Host büyütmeyi belgelenmemiş alanlarla üretir. Bu alanlar **tek bir Swift tipinde/dosyasında** toplanır (`VirtualDisplay` kuralı gibi); başka hiçbir yer alan numaralarını bilmez.
3. Qt iptali "bitti"ye çevirmediği için host her hareketi "bitti" ile kapatır. Dokunmatik ekranda yakınlaştırma merkezinin doğru olması için host BEGAN'da imleci iki parmağın ortasına taşır.

## Sonuçlar
- Krita, Safari, Preview gibi uygulamalar trackpad'deki gibi yakınlaşır. Chromium tabanlı uygulamalarda ilk birkaç değişim yutulabilir (MMF notu); gerekirse ilk değişim güçlendirilir.
- Belgelenmemiş alanlar bir macOS güncellemesiyle bozulabilir. Bozulursa yedek: MMF'nin `IOHIDEvent` yolu (özel API, yeni karar) ya da uygulamaya göre tuş kısayolu (Cmd+= / Cmd+-).
- Döndürme hareketi (alan 110 = 5) ileride aynı mesaja alan eklenerek gelebilir.
