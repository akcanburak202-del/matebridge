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
| 0010 | Oturum şifrelemesi: eşleşme anahtarı + geçici ECDH, AES-256-GCM kayıtları | kabul (kısmen 0018 ile değişti) |
| 0011 | Ses aktarımı: Core Audio process tap, sıkıştırmasız PCM, kontrol bağlantısı | kabul |
| 0012 | Tablette ses çıkışı için AAudio MMAP (NDK + C++) | kabul |
| 0013 | Akış sırasında ayarlar paneli: Ctrl+Shift+6 + Mac menüsü, sağ yan panel, bit hızı tabletten | kabul |
| 0014 | Oyun modu: 120 fps, %66, en düşük gecikme; geçici varsayılanlar | kabul |
| 0015 | Tablet dosyaları Mac'te: tablette WebDAV sunucusu, yalnızca USB tüneli üzerinden | kabul (madde 1 → 0028) |
| 0016 | Oyun modunun iki biçimi: Oyun 120 ve Oyun 60 | kabul (0030 ile "Oyun + kare hızı" oldu) |
| 0017 | Çizim modu: kararlı 120 fps, %90 | geri alındı (2026-10-03) |
| 0018 | Tablet tarafında güven onayı ve yalnızca kullanıcının başlattığı eşleşme | kabul |
| 0019 | Girdi yalnızca görüntü sağlıklıyken açık | kabul |
| 0020 | Sanal ekranın ömrü oturumdan ayrılır (bekletilen ekran) | önerildi |
| 0021 | `capture_time_us`'in anlamı ve gecikme sayıları | kabul (A) |
| 0022 | Birleştirme kapısı olarak GitHub Actions CI | kabul |
| 0023 | Wi-Fi tıkanıklığı TCP üzerinde çözülür: önce sabit Wi-Fi profili, gerekirse uçuştaki bayt bütçesi ve canlı bit hızı | önerildi (düşük öncelik) |
| 0024 | Wi-Fi'de kalem örneklerini zamana yayma (deneysel, sınırlı) | önerildi (park) |
| 0025 | Ağ tıkanmasından sonra bayat girdi politikası | ilke olarak kabul |
| 0026 | Deney ayarları (knob) politikası ve sınıflandırması | kabul |
| 0027 | Host'ta "Yalnız USB" ağ profili | kabul |
| 0028 | Tablet dosya paylaşımı: seçilen klasör ve salt okunur seçeneği (0015'i değiştirir) | kabul |
| 0029 | Oyunlar için düşük çözünürlüklü sanal ekran | kabul |
| 0030 | Modlar sadeleşir: Günlük / Çizim / Oyun; kare hızı ve oyun çözünürlüğü ayrı ayar | kabul |
| 0031 | Boşta karartma ve kapatma (tablet): panelden 2/5/10/15/kapalı, kısma → 1 dk sonra kapatma, ilk dokunuş yutulur, Oyun modunda yok | kabul |
| 0032 | HDR10 akış (HEVC Main10 PQ), yalnız Oyun modunda, panelden isteğe bağlı; STREAM_PREFS dynamic_range grubu | kabul |
| 0033 | Keskin renk kenarları (host luma ayarlı 4:2:0) panelden isteğe bağlı, varsayılan kapalı; STREAM_PREFS chroma baytı | kabul |
| 0038 | Uzaktan bağlantı: "Uzaktan bağlan" düğmesi, en az veri profili, AAC ses, uzaktan eşleşme yok | kabul |
