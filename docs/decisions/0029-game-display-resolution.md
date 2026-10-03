# 0029 — Oyunlar için düşük çözünürlüklü sanal ekran

- **Durum:** önerildi
- **Tarih:** 2026-10-04

## Bağlam

Kaynak: 2026-10-04 oyun ölçümü (docs/NOTES.md), kullanıcı isteği ("oyunlar için daha düşük çözünürlükte sanal ekran mantıklı").

Bugün sanal ekran her modda HiDPI: 1400×920 **nokta** = 2800×1840 **piksel** (`VirtualDisplay.swift`, hiDPI=1). Sonuçları:
- Oyun en fazla 1400×920'yi görüyor ve çoğu zaman o çözünürlükte çiziyor (Ori ayarlarında en yüksek 1400×920). macOS bu görüntüyü 2800×1840'a büyütüp birleştiriyor.
- Yakalama, encoder, USB ve tablet çözücüsü her karede tam 2800×1840 ile çalışıyor. Tablette çözme p50 ~18 ms; Oyun 120'nin %66 ölçeği (`scale_permille`) yalnız encode boyutunu küçültüyor, ekran 2800×1840 kalıyor.
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

Tel biçimi: büyük olasılıkla değişmez (`STREAM_PREFS` boyutu ve `scale_permille` zaten var; host ekran boyutunu istemcinin istediği boyuttan kurabilir). Kesinleşmeden önce PROTOCOL §0x05 incelenir; gerekirse ayrı protokol kararı.

**Kullanıcı onayı bekliyor.**

## Sonuçlar

- Kartlar (kabulden sonra): host ekran kurulumunda HiDPI/boyut seçimi (VirtualDisplay tek dosya kuralı korunur), istemcide ayar ve ölçek, cihaz ölçümü (çözme süresi, gecikme, takılma, Mac GPU).
- 0014 ve 0016 ile ilişkisi: oyun modlarının çözünürlük alanı bu kararla tanımlanır; 0016'daki "yenileme hızı değişince yeniden kurulum" kuralına "HiDPI/boyut değişince" eklenir.
