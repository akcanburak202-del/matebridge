# 0020 — Sanal ekranın ömrü oturumdan ayrılır (bekletilen ekran)

- **Durum:** önerildi
- **Tarih:** 2026-10-03

## Bağlam
Kaynak: dış mimari incelemesi 2026-10-03 (HEAD a30c769), H04, A1, D4, F2 ve X7. Doğrulama: `docs/reviews/2026-10-03/verify-D-display.md` (H04, P-1). Bulgu doğrulandı. Ürün hedefi için önemi High: tablet tek ana ekran (NOTES 2026-09-29).

Bugün oturum her bittiğinde 10 sn'lik bir bekleme başlar, sonra sanal ekran kaldırılır:
- Oturum sonu tablet BYE'ı, bağlantı kopması ya da host uykusu olabilir. Tablet arka plana geçince, ekranı kapanınca ya da kilitlenince de BYE gönderir (`MainActivity.kt:1758-1784`).
- İlgili kod: `DisplayLease.swift:9` (`defaultGraceUs = 10_000_000`), `:59-67`, `StreamCoordinator.swift:392-407`.
- Sanal ekran kalkınca pencereler 1920×1080 yedek ekrana taşınıp geri geliyor ve paneller kayıyor (NOTES 2026-09-30, 2026-10-02 13:45).
- Bekleme süresince yakalama ve kodlama boşuna çalışıyor (`startDrain`, `StreamCoordinator.swift:403-405, 719-724`).
- 10 sn bir ölçümle seçilmedi (T-014).

İkinci bir kaldırma yolu daha var: herhangi bir yakalama ya da kodlayıcı hatası ekranı hemen siliyor (`VideoPipeline.swift:290-301`), ve bekleme sırasında yeniden kuran yok. Bu yüzden T-132'nin "uyanınca ekran yeniden kullanılır" varsayımı büyük olasılıkla yanlış.

Kısıtlar:
- Ekran host sürecinden uzun yaşayamaz.
- Yenileme hızı değişirse yeni ekran gerekir (T-049).
- Ekranlar uykudayken yeni ekran kurulamaz (T-040).
- **Bilinmeyen:** tutulan bir `CGVirtualDisplay`, ekran uykusunu ve sistem uykusunu atlatabiliyor mu?
- Bugünkü 10 sn'lik kaldırma aynı zamanda örtük bir kurtarma yolu. Tablet tamamen gidince Mac yedek ekrana, dolayısıyla Parsec'e döner.

## Seçenekler
- **(a) Olduğu gibi kalsın.** 10 sn bekleme, bu sürede yakalama ve kodlama çalışır.
- **(b) Ekran Quit'e kadar tutulsun.** Pencere düzeni hiç bozulmaz, ama örtük kurtarma yolu kaybolur.
- **(c) Oturum bitince ekran "bekletilir" (önerilen).**
  - Girdi bırakılır.
  - Yakalama, kodlama ve ses durur.
  - Ekranın kimliği, boyutu ve yenileme hızı korunur.
  - Aynı cihaz uyumlu boyutla dönerse medya bekletilen ekran üzerinde yeniden kurulur. Bu, T-049'daki `stopKeepingDisplay()`/`init(reusing:)` yolunu kullanır.

  Ekran şu durumlarda kaldırılır:
  - bekletme süresi dolunca (10 sn / 5 dk / 30 dk / Quit'e kadar);
  - menüde "Sanal ekranı şimdi kaldır" seçilince;
  - farklı bir cihaz ya da boyut bağlanınca;
  - yenileme hızı değişince;
  - host kapanınca.

## Karar
Önerilen: **(c)**. Dürüst ömür tanımı "host süreci boyunca, kullanıcı tercihiyle sınırlı". Ekran host'tan uzun yaşayamaz.

Varsayılan bekletme süresi T-166 ölçümünden sonra seçilir. Ölçüm şunlara bakar: bekletilen ekran ekran uykusunu ve sistem uykusunu atlatıyor mu, pencere yerleşimi korunuyor mu, Parsec ekranı görebiliyor mu?

Süre duvar saati olarak düşünülüyorsa sürekli saat (`mach_continuous_time`) kullanılır. `HostClock` uykuda ilerlemez (D ek 5). **Kullanıcı onayı bekliyor.** Kullanıcı cevabı (2026-10-03, soru 1): uzak erişim Parsec; Parsec ulaşamazsa son çare Mac'e HDMI kablosuyla monitör bağlamak. FileVault kapalı. Varsayılan süre (soru 2) T-166'dan sonra sorulur.

Kullanıcının cevaplaması gerekenler (manifest §5):
1. **Varsayılan bekletme süresi (soru 2):** 10 sn, 5 dk, 30 dk ya da "Quit'e kadar"? Cevap T-166'dan sonra verilir.
2. **İkinci erişim yolu (soru 1):** tablet hiçbir şey göstermediğinde hangi uzak yola güveniyorsun: yalnızca Parsec mi, yoksa SSH ya da macOS Ekran Paylaşımı da var mı? FileVault açık mı? Bu, uzun bekletmenin örtük kurtarma yolunu kapatmasının ne kadar riskli olduğunu belirler. Yedek ekran fiziksel monitör değil, başsız Mac'in 1920×1080 yedek ekranı (NOTES.md:160).

## Sonuçlar
- **Kazanılan:**
  - Kısa kopmalarda, ekran kapanınca ya da arka plana geçince pencere düzeni korunur.
  - Bekletme sırasında maliyet ~0 olduğu için süreyi uzatmak ucuzlar.
  - Açık bir "kaldır" eylemi gelir.
- **Kaybedilen:** uzun bekletmede Mac yedek ekrana geç döner. Bunu "Sanal ekranı şimdi kaldır" telafi eder.
- **Kapıladığı kartlar:**
  - T-167: bekletme tercihi ve "şimdi kaldır" menüsü.
  - T-200: hatada sağlam ekranı koruma; ayrıca T-166 sonucuna bağlı.
  - Kapılı olmayanlar: T-165 (bekletme mekanizması, 10 sn varsayılanla) ve T-166 (ölçüm) karar beklemeden başlar.
- **Mevcut kararlar:** 0016'da "her mod değişimi sanal ekranı yeniden kuruyor" ifadesi düzeltilir. Yalnızca yenileme hızı değişimi ekranı yeniden kurar (D ek 7).
- **Diğer belgeler:** PROTOCOL.md değişmez. PLAN Aşama 4'teki "Mod seçimi" maddesi güncellenir.
- **Tekrar düşünülür:**
  - T-166, macOS'un uykuda sanal ekranı yine de çevrimdışı yaptığını gösterirse;
  - `CGVirtualDisplay` bir macOS güncellemesiyle bozulursa (ayrı karar, manifest §5 soru 12);
  - host çökünce kendini yeniden başlatma kararı alınırsa (T-202).
