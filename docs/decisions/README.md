# Karar kayıtları

Geri dönmesi pahalı ya da birden fazla ajanı etkileyen her karar burada kısa bir dosya olarak yazılır: `NNNN-kisa-ad.md`. Sohbette verilip burada olmayan karar, ajanlar için yoktur.

Şablon:

```markdown
# NNNN — Başlık

- **Durum:** önerildi | kabul | yerini aldı: NNNN
- **Tarih:** YYYY-AA-GG

## Bağlam
Neden karar gerekti? (2–5 cümle)

## Karar
Ne seçildi?

## Sonuçlar
Kazanılan, kaybedilen, neyi tetikler. Hangi koşulda tekrar düşünülür.
```

| No | Karar | Durum |
|---|---|---|
| 0001 | Hazır çözüm yerine özel uygulama, önce yerel ağ | kabul |
| 0002 | Mac tarafı yalnızca Swift Package Manager (xcodeproj yok) | kabul |
| 0003 | Klavye: karakter değil fiziksel tuş kodu | kabul |
| 0004 | Android: Views + SurfaceView, Compose yok, GMS yok | kabul |
| 0005 | Yalnızca test için bağımlılıklar (JUnit 4, kotlin-test, XCTest) kayıt gerektirmez | kabul |
| 0006 | Faz 2 girdi: çift dokunma = fırça/silgi geçişi (eraser pointer), çizimde parmak kapalı, yan tuş yok | kabul |
| 0007 | Kalem teması doğrulanmadan gönderilmez | kabul |
| 0008 | Klavye: varsayılan değiştirici eşlemesi ve ISO düzeni | kabul |
| 0009 | İki parmakla yakınlaştırma: PINCH mesajı ve belgelenmemiş büyütme olayı | kabul |
| 0010 | Oturum şifrelemesi: eşleşme anahtarı + geçici ECDH, AES-256-GCM kayıtları | kabul |
| 0011 | Ses aktarımı: Core Audio process tap, sıkıştırmasız PCM, kontrol bağlantısı | kabul |
| 0012 | Tablette ses çıkışı için AAudio MMAP (NDK + C++) | kabul |
| 0013 | Akış sırasında ayarlar paneli: Ctrl+Shift+6 + Mac menüsü, sağ yan panel, bit hızı tabletten | kabul |
| 0014 | Oyun modu: 120 fps, %66, en düşük gecikme; geçici varsayılanlar | kabul |
