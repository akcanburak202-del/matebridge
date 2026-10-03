# 0029 — Oyunlar için düşük çözünürlüklü sanal ekran

- **Durum:** kabul (2026-10-04); protokol ayrıntısı T-212 tasarımıyla kesinleşir
- **Tarih:** 2026-10-04

## Bağlam

Kaynak: 2026-10-04 oyun ölçümü (docs/NOTES.md), kullanıcı isteği ("oyunlar için daha düşük çözünürlükte sanal ekran mantıklı").

Bugün sanal ekran her modda HiDPI: 1400×920 **nokta** = 2800×1840 **piksel** (`VirtualDisplay.swift`, hiDPI=1). Sonuçları:
- Oyun en fazla 1400×920'yi görüyor ve çoğu zaman o çözünürlükte çiziyor (Ori ayarlarında en yüksek 1400×920). macOS bu görüntüyü 2800×1840'a büyütüp birleştiriyor.
- Oyun 60'ta yakalama, encoder, USB ve tablet çözücüsü her karede tam 2800×1840 ile çalışıyor; tablette çözme p50 ~18 ms. Oyun 120'nin %66 ölçeğinde SCK zaten 1848×1214 veriyor (yakalama/encode/çözme küçük), ama ekran 2800×1840 HiDPI kalıyor. **Düzeltme (2026-10-04, astra değerlendirmesi):** önceki metin Oyun 120'de yalnız encode'un küçüldüğünü söylüyordu; yanlış. 1x oyun ekranının Oyun 120'deki farkı birleştirme/ölçekleme ve oyunun görebildiği kiplerdir; çözme kazancı yalnız Oyun 60'ta beklenir. Ayrıca 1400×920 seçen bir oyun 1848×1214'e geçerse kendi çizim yükü artabilir. T-216 aynı kodlanan boyutu farklı ekran topolojisiyle de karşılaştırmalı.
- Ekran çözünürlüğü ve yenileme hızı değişince macOS sanal ekranı yeniden kurmak zorunda (0016, T-049); pencereler kısa süre yedek ekrana taşınıp geri gelir, bazı uygulamalar (Krita) paneli yeniden çizmez.

## Seçenekler

- **(a) Bugünkü gibi** (her modda 2800×1840 HiDPI).
- **(b) Oyun ekranı çözünürlüğü (önerilen):** oyun modlarında sanal ekran **HiDPI olmadan**, seçilen piksel boyutunda kurulur (ör. 1400×920, 1848×1214, 2100×1380; en-boy 2800×1840 ile aynı). Oyun bu boyutu tam ekran çözünürlüğü olarak görür; yakalama/encode/çözme bu boyutta yapılır, tablet ekrana büyütür.
  - Kazanılan: tablette çözme ve aktarım küçülür (1400×920'de piksel sayısı dörtte bir; çözme süresinin belirgin düşmesi beklenir → daha düşük gecikme, 120 fps'e daha rahat), Mac'te birleştirme ve yakalama yükü azalır, USB bant genişliği rahatlar.
  - Kaybedilen: oyun modundayken Mac masaüstünün geri kalanı da (menü çubuğu, diğer pencereler) aynı düşük çözünürlükte ve 1x görünür; yazılar daha iri ve yumuşak olur. Oyun moduna girerken ve çıkarken ekran yeniden kurulur (~1 sn siyah, pencere yerleşimi bir an kayar).
- **(c) Yalnız encode ölçeği** (bugünkü %66 gibi): ekran 2800×1840 kalır. Mac tarafı yükü değişmez; oyun yine yalnız 1400×920'yi görür. Sorunu çözmez.

## Karar

Önerilen: **(b)**. Ayrıntılar kullanıcı cevaplarına göre kesinleşir:
1. Sunulacak boyutlar ve varsayılan.
2. Seçim nerede: oyun modlarının bir ayarı mı ("Oyun çözünürlüğü"), yoksa ayrı bir görüntü modu mu.
3. Giriş/çıkışta ekranın yeniden kurulmasının kabulü.

Tel biçimi (2026-10-04, T-213): `STREAM_PREFS` sonuna isteğe bağlı `display_width_px`/`display_height_px` grubu (u16, yoksa 0 = doğal HiDPI). Yeni mesaj yok; eski istemci 8 bayt gönderir (doğal ekran), eski host grubu yok sayar ve `scale_permille`'i uygular (bugünkü Oyun 120/60 davranışı). Ayrıntı PROTOCOL §2 ve §0x05.

**Kullanıcı 2026-10-04'te onayladı:**
1. Üç boyut: 1400×920 · 1848×1214 · 2100×1380; varsayılan 1848×1214.
2. Seçim oyun modlarının ayarı ("Oyun çözünürlüğü"): Oyun 120 / Oyun 60'a girince uygulanır, diğer modlar tam çözünürlükte (2800×1840 HiDPI) kalır.
3. Giriş/çıkışta ekranın yeniden kurulması (~1 sn, pencereler bir an kayabilir) ve oyun modunda Mac masaüstünün de düşük çözünürlükte görünmesi kabul.

## Sonuçlar

- Kartlar: T-213 (protokol + codec + fixture), T-214 (host), T-215 (istemci), T-216 (cihaz ölçümü).
- 0014 ve 0016 ile ilişkisi: oyun modlarının çözünürlük alanı bu kararla tanımlanır; 0016'daki "yenileme hızı değişince yeniden kurulum" kuralına "HiDPI/boyut değişince" eklenir.
