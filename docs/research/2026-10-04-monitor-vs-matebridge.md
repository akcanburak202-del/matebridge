# Normal monitör ve MateBridge: görüntü yolu, verim ve cihaz ömrü (2026-10-04)

Kaynak: orkestratörün başlattığı araştırma ajanı. Web kaynakları, repo okuması, tablette salt okunur `dumpsys battery|display|thermalservice` ve Mac'te salt okunur `pmset -g`, `defaults read`. Ürün kodu değişmedi.

Kullanıcının sorusu: "Normal bir monitör nasıl çalışır, görüntü ona nasıl gelir? MateBridge bu sistemden nerede ayrılıyor? Verim ve cihazların uzun vadeli ömrü açısından karşılaştır."

Etiketler:

- **[ölçüm]** bu projede cihazda ölçüldü (NOTES veya bugünkü okuma).
- **[kaynak]** web kaynağı. Üretici iddiasıysa ayrıca belirtilir.
- **[tahmin]** hesap ya da makul varsayım, ölçülmedi.
- **[çıkarım]** kanıttan çıkarılan ama doğrulanmamış sonuç.

## Kısa cevap

- **Normal monitör** görüntüyü neredeyse hiç işlemeden alır. GPU'nun bellekteki karesi, kablo üzerinden piksel piksel ve sıkıştırılmadan (ya da DSC ile "gözle ayırt edilemez" şekilde) panele akar. Eklediği gecikme genelde 5–20 ms, renk 4:4:4, 8–10 bit ve HDR mümkün.
- **MateBridge** aslında bir "görüntülü yayın". Mac görüntüyü sanal bir ekrana çizer. Bu görüntü yakalanır, donanım kodlayıcısıyla HEVC'ye sıkıştırılır (yaklaşık 125–250 kat), USB ya da Wi-Fi ile gönderilir, tablette açılıp OLED'e basılır. Bedeli 30–55 ms ek gecikme ve 4:2:0, 8-bit, SDR görüntüdür. Karşılığında bir monitörde hiç olmayan şeyler gelir: basınçlı kalem, klavye, trackpad ve ses. MatePad'in USB-C'si görüntü **almadığı** için "gerçek kablolu monitör" yolu bu tablette yok.
- **Verim:** Mac tarafı ucuz. Kodlama ayrı donanım biriminde yapılıyor, MateBridgeApp yayın sırasında bir çekirdeğin ~%10–12'sini kullanıyor. Asıl yük tablette: oyunda 60 fps çözme bir çekirdeği neredeyse dolduruyor, SoC ~37–40 °C oluyor.
- **Ömür, en önemli risk OLED yanması.** macOS'in sabit menü çubuğu, Dock'u ve pencere çerçeveleri her gün saatlerce aynı piksellerde duruyor. Tandem OLED ve otomatik parlaklık bu riski azaltıyor, ama ortadan kaldırmıyor.
- **Yeni bulgu:** bugünkü kodda iki taraf da ekranı açık tutuyor. Tablet `FLAG_KEEP_SCREEN_ON` kullanıyor, Mac de oturum boyunca `PreventUserIdleDisplaySleep` tutuyor. Yani masadan kalkınca hiçbir şey kendiliğinden kararmıyor. Tek otomatik koruma, varsa macOS ekran koruyucusu. T-128'in "boşta kalmayı tabletin kendi ekran zaman aşımı yönetir" varsayımı bu yüzden bugün geçerli değil.
- **Pil:** tablet şu an prizde ama **%78'de şarj olmuyor** ([ölçüm] `status: 4` = not charging). Bu, Huawei Akıllı Şarj'ın %80 civarında beklettiğini gösteriyor [çıkarım]. Bu iyi bir durum. Pil için kötü olan, %100'de ve sıcak beklemek.
- **Mac ve SSD:** kare başına diske yazma yok. Log dosyaları dönüyor ve en çok 50 MB yer tutuyor. Aşınma açısından önemsiz.

## 1. Normal bir monitör nasıl çalışır?

### 1.1 Kare nereden çıkar?

1. Uygulamalar pencerelerini çizer. macOS'te **WindowServer** bunları birleştirip ekranın son karesini GPU belleğindeki bir **framebuffer**'a yazar. M serisi çiplerde bu bellek ortak bellektir.
2. Çipin içindeki **display engine** (ekran denetleyicisi) bu kareyi her yenilemede baştan sona okur. İmleç ve video gibi katmanları ekler, renk ve gama düzeltmesini uygular, ardından pikselleri satır satır sabit bir zamanlamayla dışarı verir. Bu işleme **scanout** denir. Bu aşamada sıkıştırma ya da kodlama yoktur. Kare, ekran yenilendikçe olduğu gibi okunur.

### 1.2 Kablo

- **DisplayPort** (ve USB-C'deki **DP Alt Mode**, Thunderbolt içindeki DP tüneli) ile **HDMI** ham piksel akışını taşır.
- Bu tabletin çözünürlüğünde gereken bant genişliği [tahmin, hesap]:
  - 2800×1840, 60 Hz, 8-bit RGB: 5,15 MP × 24 bit × 60 ≈ **7,4 Gbit/s**, artı boşluk (blanking).
  - 120 Hz'te ≈ 14,8 Gbit/s.
  - 10-bit, 120 Hz'te ≈ 18,5 Gbit/s.
- Sığmazsa **DSC** (Display Stream Compression) devreye girer. DSC en çok ~3:1 sıkıştırır, VESA bunu "visually lossless" olarak tanımlar ve satır düzeyinde çalıştığı için gecikmesi çok küçüktür [kaynak: VESA]. Yine de kayıplı bir sıkıştırmadır. Ama MateBridge'deki HEVC'den (~125–250:1) yaklaşık 40–80 kat daha hafiftir.

### 1.3 Zamanlama

- Monitör sabit bir yenileme hızında çalışır, örneğin 60 Hz'te her 16,7 ms'de bir kare.
- Her yeni kare **vsync** anında başlar. GPU kareyi vsync'e yetiştiremezse önceki kare bir kez daha gösterilir.
- **VRR** (Adaptive-Sync, G-Sync, ProMotion) yenilemeyi kare hazır olduğunda başlatır. Böylece hem bekleme hem takılma azalır.

### 1.4 Panel

- Monitörün içindeki **TCON** (timing controller) gelen akışı panelin satır ve sütun sürücülerine dağıtır. Varsa ölçekleme ve LCD'de overdrive gibi işlemleri yapar.
- **LCD:** arkada sürekli yanan bir LED aydınlatma, önünde ışığı geçiren ya da kesen sıvı kristal vardır. Siyah tam siyah olmaz. Kalıcı yanma pratikte görülmez. LED aydınlatma yıllar içinde yavaşça kararır.
- **OLED:** her alt piksel kendi ışığını üretir. Siyah gerçek siyahtır, tepki hızlıdır. Ama her piksel ne kadar parlak ve ne kadar uzun yandıysa o kadar yaşlanır, en hızlı da mavi. Hep aynı yerde duran parlak bir öğe, o pikselleri komşularından daha hızlı eskitir. Sonuç kalıcı bir gölge olur, buna **yanma** (burn-in) denir. OLED monitörlerde buna karşı piksel kaydırma (pixel shift), "pixel refresh" ve logo karartma gibi bakım işlevleri bulunur [kaynak].

### 1.5 Gecikme, güç, kalite

- **Gecikme:**
  - Monitörün kendisinin eklediği süre (işleme + taramanın ekran ortasına ulaşması) RTINGS ölçümlerinde LCD'lerde tipik olarak ~4–12 ms, OLED monitörlerde 1–3 ms [kaynak].
  - Buna, karenin bir sonraki vsync'i beklemesi eklenir: 60 Hz'te 0–16,7 ms, ortalama ~8 ms.
  - Toplamda ekran tarafı **~5–20 ms** ekler [tahmin].
- **Güç:** 27" 4K bir LCD monitör tipik olarak 17–30 W çeker (ör. Dell U2720Q: tipik 17 W, en çok 30 W) [kaynak]. Mac'in display engine'i bu iş için kayda değer enerji harcamaz.
- **Kalite:** kayıpsız ya da DSC ile görsel olarak kayıpsız. RGB 4:4:4, yani her piksel tam renk bilgisi taşır. 8 ya da 10 bit, monitör destekliyorsa HDR.

## 2. MateBridge'in yolu

### 2.1 Görüntü (Mac → tablet)

| Adım | Ne olur | Süre / değer |
|---|---|---|
| 1. Sanal ekran | `CGVirtualDisplay` ile 2800×1840 HiDPI ekran (1400×920 nokta) kurulur. macOS buna gerçek monitörmüş gibi çizer. Özel API yalnız `VirtualDisplay` tipinin arkasında. | 60 ya da 120 Hz |
| 2. Yakalama | ScreenCaptureKit kareyi (420f, full range) yalnız ekran değişince verir. | Durgun ekranda ~30 s'de bir kare [ölçüm] |
| 3. Kodlama | VideoToolbox HEVC Main, 8-bit 4:2:0, BT.709, SDR. Ayrı donanım biriminde (media engine) çalışır. | `enc` ~5–8 ms [ölçüm] |
| 4. Şifre + gönderim | AES-GCM oturum şifrelemesi (karar 0010). TCP, USB'de `adb reverse` (USB 2.0) ya da Wi-Fi'de BSD soketi (T-091). | `cap_to_sent` ~7 ms [ölçüm] |
| 5. Çözme | `OMX.hisi.video.decoder.hevc` (donanım). | 120 fps'te ~9 ms, 60 fps'te `oprate=max` ile ~13–14 ms (önce 17–18) [ölçüm, T-222] |
| 6. Zamanlama | Uyarlamalı zamanlayıcı kareyi panelin bir vsync'ine yerleştirir. | |
| 7. Gösterim | SurfaceFlinger BT.709'u Display P3 panele dönüştürür. Panel boşta 60 Hz'te, dokunulunca 120 Hz'e çıkar (Huawei AGP kuralı). | [ölçüm, T-188 / T-048] |

Bit hızı:

- Otomatik: 30 Mbps.
- Çizim ve Oyun: 60 Mbps.
- Kayan metinde fiilen gönderilen ~23 Mbps [ölçüm].
- Durgun ekranda neredeyse 0.

Bu, 7,4 Gbit/s'lik ham akışın yaklaşık 125–250 kat sıkıştırılması demek.

### 2.2 Girdi (tablet → Mac) ve ses

- **Kalem:** `MotionEvent` verisi (basınç, eğim, hover, geçmiş örnekler, ~360 örnek/s) kontrol bağlantısıyla (TCP, `TCP_NODELAY`) gider. Mac'te `CGEvent` tablet olayı olarak enjekte edilir. USB'de olaylar Mac'e 2,8 ms aralıkla ulaşıyor [ölçüm].
- **Klavye:** karakter değil scan code gider (karar 0003).
- **Trackpad:** pointer capture ile göreli hareket gönderilir.
- **Ses:** Mac'in sistem sesi tablete uçtan uca ~41 ms'de gelir [ölçüm].

Normal monitörde bunların hiçbiri yoktur. Kalemli ekranlar (ör. Wacom Cintiq) bu iş için ayrı bir USB kablosu kullanır.

### 2.3 Benzer çözümler

| Çözüm | Nasıl çalışır | Android'den basınçlı kalem | Not |
|---|---|---|---|
| **Apple Sidecar** | iPad'e kablolu ya da kablosuz (10 m, Wi-Fi + Bluetooth + Handoff) sıkıştırılmış video akışı [kaynak: Apple]. | Yok (yalnız iPad + Apple Pencil) | Kodlama ayrıntısını Apple yayımlamıyor. |
| **Duet Display** | Benzer yayın. | Zayıf (PLAN §2) | Basınç ve eğim iPad odaklı. |
| **Parsec** | Oyun yayını, HEVC/H.264. | Yok | Mac host'ta 4:4:4 yok (PLAN §2). Kullanıcı: MateBridge "kat be kat keskin" (NOTES 09-29). |
| **Moonlight + Sunshine** | Oyun yayını, düşük gecikme. | Yok | Sunshine'ın Mac desteği zayıf. |
| **DisplayLink (USB monitör)** | Mac'teki sürücü ekranı yakalar ("Screen Recording" izni ister), sıkıştırır, USB'den adaptöre yollar. Adaptör açıp gerçek monitöre HDMI/DP verir [kaynak]. | Yok | Mimari olarak MateBridge'in en yakın akrabası: o da "dolaylı ekran". |
| **MateBridge** | Sanal ekran + HEVC + TCP, girdi geri kanalı. | **Var** (basınç, eğim, hover) | Bu tablet için tek bütün çözüm. |

### 2.4 MatePad neden gerçek kablolu monitör olamaz?

- Tabletin paneli içeride doğrudan SoC'nin ekran denetleyicisine bağlı. USB-C portundan bu denetleyiciye giden bir **görüntü girişi** yolu yok.
- Tabletlerdeki DP Alt Mode, varsa, yalnız **çıkış** yönündedir: tabletin görüntüsünü harici ekrana verir. USB-C'de görüntü takılsa da Android'in "görüntü al" diye bir sistem işlevi yoktur [kaynak].
- Tek dolambaçlı yol bir HDMI→USB yakalama kartı (UVC) ve tablette bir izleyici uygulamasıdır. Ama:
  - Mac karttaki 16:9 EDID'i görür, 2800×1840 3:2 doğal çözünürlük gelmez.
  - Görüntü yine sıkıştırılır (MJPEG ya da düşük çözünürlüklü ham YUV), çünkü bu bağlantı USB 2.0 (480 Mbit/s) ve ham 7,4 Gbit/s'e yetmez.
  - Kalem ve klavye Mac'e gitmez.

  Yani bu yol MateBridge'in daha kötü bir kopyası olurdu.

Sonuç: bu tablette "monitör gibi" çalışmanın tek pratik yolu, MateBridge'in yaptığı türden bir yayındır.

## 3. Yan yana karşılaştırma

| Ölçüt | Normal monitör (DP/HDMI) | MateBridge, USB | MateBridge, Wi-Fi |
|---|---|---|---|
| Ekrana eklenen gecikme | ~5–20 ms [kaynak/tahmin] | Yakalama→gösterim: Çizim 120'de **38–40 ms**, Oyun 60'ta (panel 60 Hz) **53–65 ms** [ölçüm, NOTES 10-04]. Artı içerik→yakalama ~4 ms ve tarama ~4–9 ms [tahmin]. | USB'den ~15–25 ms fazla [ölçüm: yakalama→çözülmüş kare USB 19–25 ms, Wi-Fi ~38–49 ms, NOTES 10-01] |
| Monitöre göre fark | — | **+30–50 ms** [tahmin] | **+45–70 ms** [tahmin] |
| Mac aşamaları | Yok | Kodlama 5–8 ms, `cap_to_sent` ~7 ms | Aynı |
| Tablet çözme | Yok | 9 ms (120 fps), 13–14 ms (60 fps) | Aynı |
| Renk / chroma | RGB 4:4:4, 8–10 bit, HDR olabilir | HEVC 4:2:0, 8-bit, SDR, BT.709 full range [ölçüm T-188] | Aynı |
| Görüntü doğruluğu | Kayıpsız ya da DSC (görsel kayıpsız) | Aralık doğru (0/16/235/255 korunuyor). En koyu basamaklar biraz eziliyor (1→0, 2→0, 4→2, 8→6). Renkler P3 panele doğru dönüştürülüyor. İnce renkli yazının kenarları biraz yumuşak. 30 ve 100 Mbps arasında fark yok. [ölçüm] | Aynı (bit hızı Wi-Fi'de daha düşük olabilir) |
| HDR | Monitör destekliyorsa var | Yok, sanal ekran SDR (T-226 araştırıyor) | Yok |
| Bant genişliği | 7,4 Gbit/s (60 Hz), 14,8 Gbit/s (120 Hz) | 23–60 Mbps, durgunken ~0 | Aynı. Wi-Fi'de ~400 Mbit/s kapasite var [ölçüm] |
| Mac CPU | ~0 | MateBridgeApp yayında bir çekirdeğin ~%10–12'si, boşta %0–0,4 [ölçüm] | Aynı |
| Mac GPU | Masaüstünü çizmek (aynı iş) | Aynı çizim + yakalama dönüşümü (küçük). Oyunda yükü belirleyen oyunun kare hızı: Oyun 120'de GPU %90, Oyun 60'ta %54; MateBridgeApp farkı ~%1 [ölçüm] | Aynı |
| Mac güç | Monitörün kendisi 17–30 W | Ölçülemedi (`powermetrics` M6'da 0 mW gösteriyor). Kodlayıcı ayrı birimde, ek yük ~1 W düzeyi [tahmin]. Mac mini boşta ~4–5 W (M4 sınıfı, Apple) [kaynak] | Aynı |
| Tablet CPU | — | Durgun ekran: istemci bir çekirdeğin ~%7–10'u (toplam ~45–56/800). Oyun 60 fps: ~%95–100 (toplam ~200–240/800). Çizim 120: toplam ~157/800 [ölçüm] | Benzer, `adbd` yok |
| Isı | Monitör pasif, ılık | 5 dk oyunda SoC ~37–40 °C, frekans düşüşü yok. Bugün boşta: gövde 30,8 °C, pil 29 °C [ölçüm] | Benzer |
| Tablet enerjisi | — | Ölçülmedi. Ekran + çözme birkaç W [tahmin]. USB'den beslenir, pil %80 civarında bekler | Pilden: şarj/deşarj döngüsü |
| Girdi | Yok | Kalem (basınç/eğim), klavye, trackpad, dokunma, ses | Aynı. Kalem Wi-Fi'de öbekleniyor (0024 park) |

Gecikme notu: monitörde de Mac'in kareyi çizme süresi vardır. Tabloda yalnız ekran tarafının **eklediği** süre karşılaştırılıyor. Kalem çiziminde göz ~40 ms'lik farkı hissedebilir. Araştırmalar sürüklemede 2–6 ms'ye kadar algılanabildiğini, yazıda ~50 ms'ye kadar tolere edildiğini gösteriyor (bkz. `docs/research/2026-10-04-smoothness.md` §5).

## 4. Uzun vadede cihaz ömrü

### 4.1 Tablet OLED: yanma riski

**Neden risk var?** macOS masaüstü bir OLED için "zor içerik" sayılır. Menü çubuğu, Dock, pencere başlıkları, kenar çubukları ve imlecin sık durduğu yerler her gün saatlerce aynı piksellerde durur. Monitör rehberleri, günde 8 saat ve üzeri sabit görev çubuklu masaüstü kullanımını OLED için "yüksek risk" sınıfına koyuyor [kaynak]. RTINGS'in 10.000 saatlik testinde (en yüksek SDR parlaklık, ~10 yıl × günde 5 saate denk) **bütün** OLED'lerde bir miktar iz oluştu. Daha yeni paneller daha parlak oldukları için aynı parlaklıkta daha az yıpranıyor. Yani parlaklığı düşük tutmak en etkili önlem [kaynak].

**Lehte olanlar:**

- Panel **tandem OLED**: iki ışık katmanı var, her biri daha düşük akımla çalışıyor. Huawei 2024 modeli için "standart AMOLED'in 3 katı ömür" diyor. Bu bir üretici iddiası, bağımsız test bulamadık [kaynak].
- Otomatik parlaklık açık. Bugünkü okumada parlaklık ölçeğin ~%27'si, ortam ~95 lux [ölçüm, `dumpsys display`].
- Mac **koyu modda** [ölçüm, `AppleInterfaceStyle=Dark`]: menü çubuğu ve pencereler koyu.
- MateBridge'in istatistik katmanı varsayılan olarak kapalı (`Settings.statsOverlay`, `"1"` değilse kapalı). Açık bırakılırsa o da sabit bir öğedir.

**Aleyhte olanlar:**

- Dock otomatik gizlenmiyor, menü çubuğu da hep görünüyor [ölçüm: `com.apple.dock autohide` ve `_HIHideMenuBar` tanımlı değil, yani varsayılan açık].
- **Boşta kimse ekranı kapatmıyor (yeni bulgu, koddan doğrulandı):**
  - Tablet `MainActivity.kt:380` → `FLAG_KEEP_SCREEN_ON` her zaman eklenir, hiç kaldırılmaz. MateBridge ön plandayken tabletin kendi ekran zaman aşımı çalışmaz. PLAN Aşama 4'teki "ekran uyumaz" maddesi bilerek böyle yapılmış.
  - Mac `SystemPower.swift` → `DisplaySleepAssertion` oturum boyunca `PreventUserIdleDisplaySleep` tutar. Bugün `pmset -g assertions` bunu ve `PreventUserIdleSystemSleep "MateBridge input session"` assertion'ını gösteriyor [ölçüm].
  - T-128'in gerekçesi "boşta kalmayı tabletin kendi ekran zaman aşımı yönetir" diyor. Bu yüzden zincir kopuk: kullanıcı masadan kalkınca ne tablet ne Mac ekranı kendiliğinden karartıyor. Bu durum, kullanıcının "uzun süre kullanılmayınca Mac uyusun" kararıyla (NOTES 10-02) da çelişiyor.
  - Tek otomatik koruma macOS **ekran koruyucusu**. Ekran uykusu assertion'ları ekran koruyucuyu engellemiyor [kaynak: Apple geliştirici forumu, macOS 12 denemesi]. NOTES 10-01'de Mac ~20 dk boşta kendiliğinden kilitlenmişti, bu da varsayılan ekran koruyucuyla uyumlu. macOS 27'de sanal ekranla bugün böyle çalıştığı **doğrulanmadı** [çıkarım]. Ekran koruyucu hareketli olduğu için yanmaya karşı işe yarar, ama tablet tam parlaklıkta yanmaya devam eder.
- **Piksel kaydırma:** Huawei'nin bu tablette uygulamalar için piksel kaydırma ya da "pixel refresh" yaptığına dair yayımlanmış bilgi bulamadık. MateBridge görüntüyü piksel piksel tam oturtuyor (2800×1840 → 2800×1840), dolayısıyla menü çubuğu hep aynı piksellere düşüyor.

**Normal monitörle kıyas:**

- LCD monitörde bu risk pratikte yok.
- OLED monitörde risk aynı sınıfta, ama orada piksel kaydırma ve bakım döngüleri hazır gelir. Mac ekranı uyuyunca monitör de kendiliğinden kapanır (DPMS).

**Dürüst değerlendirme [tahmin]:** günde birkaç saat koyu modda, orta parlaklıkta ve masadan kalkınca tablet ekranı kapatılarak kullanımda tandem panelde birkaç yıl içinde görünür yanma olası değil. Ama tablet tam parlaklıkta günde 8+ saat açık kalırsa, ya da boşta gece boyu yanık kalırsa (bugünkü kodla mümkün), menü çubuğu ve Dock'un izi zamanla belirebilir. Bu yıpranma geri dönmez.

### 4.2 Tablet pili

- **Bugünkü okuma [ölçüm]:** `AC powered: true`, `level: 78`, `status: 4` (not charging), `health: 2` (good), pil 29 °C, `Max charging current: 500000` µA.
- Prizdeyken %78'de şarjın durması Huawei **Akıllı Şarj**'ın çalıştığını gösteriyor. Bu özellik alışkanlıkları öğrenip pili %80'de bekletiyor [kaynak: Huawei; tabletteki ayar okunmadı, çıkarım].
- **Neden önemli:** Battery University'nin tablosuna göre bir yıl bekleyen Li-ion pilde kalan kapasite [kaynak]:

  | Sıcaklık | %40 şarjda | %100 şarjda |
  |---|---|---|
  | 25 °C | %96 | %80 |
  | 40 °C | %85 | %65 |

  Yani zarar veren şey "prizde kalmak" değil, **dolu ve sıcak beklemek**. USB'de sürekli takılı çalışan bir tablette pilin %80 ya da altında ve serin tutulması en büyük kazançtır.
- **Huawei Özel şarj sınırı** (%70 / 80 / 90 / 100, Ayarlar → Pil → Pil sağlığı) HarmonyOS **4.3.1** ve sonrasında var. Bu tablet 4.3.0.145'te, yani bugün yalnız Akıllı Şarj kullanılabilir. Huawei, cihaz uzun süre şarja bağlı kalacaksa %70 öneriyor. Akıllı Şarj ile Özel sınır aynı anda açık olamıyor [kaynak].
- **Oyunda pil:** `Max charging current` 500 mA × 5 V ≈ 2,5 W gösteriyor. Şarj duraklatılmışken bu değer anlamsız olabilir. Ama gerçekten bu kadarsa, uzun ve parlak bir oyunda tablet prizde olsa bile yavaşça boşalabilir [çıkarım, ölçülmedi]. Uzun bir oyun oturumundan sonra pil yüzdesine bakmak bunu ortaya çıkarır.
- **Wi-Fi modunda** tablet pilden çalışır, her şarj ve deşarj bir döngü sayılır. Ara sıra Wi-Fi sorun değil. Her gün sıfıra yakın boşaltıp %100'e doldurmak, prizde %80'de beklemekten daha çok yıpratır [kaynak: Battery University, genel ilke].
- **Normal monitörle kıyas:** monitörde pil yoktur, bu yıpranma tamamen MateBridge kullanımına özgüdür.

### 4.3 Isı

- **[ölçüm]**
  - 5 dk oyunda SoC ~37–40 °C, frekans düşüşü yok.
  - Çizim 120'de ~40 °C (T-222).
  - Bugün boşta CPU kümeleri ~30 °C, gövde (`shell_frame`) 30,8 °C.
- Tablet ısı sınırları (`dumpsys thermalservice`, HAL statik eşikleri) [ölçüm]:
  - CPU ve GPU için ilk kısma eşiği 55 °C.
  - **Gövde (SKIN) için 37 / 40 / 43 °C.**

  NOTES'taki "~40 °C" büyük olasılıkla SoC okuması, çünkü frekans düşmedi [çıkarım]. Gövde sıcaklığının uzun oturumdaki değeri ölçülmedi.
- Sıcaklık hem pil yaşlanmasını hem OLED yaşlanmasını hızlandırır. Bu yüzden kısa ölçümler iyi görünse de **8 saatlik** gerçek kullanım ölçülmeli (T-194 dayanıklılık testi bunun doğal yeri).
- **Normal monitörle kıyas:** monitör kendi gücüyle ısınır, ama yanında çözme yapan bir SoC ve pil yoktur.

### 4.4 Mac

- **Kodlayıcı:** HEVC kodlaması ayrı donanım biriminde yapılıyor, CPU ve GPU'yu meşgul etmiyor. Sürekli kullanımın bilinen bir aşınma etkisi yok.
- **SSD:** normal çalışmada kare başına diske yazılan bir şey yok. Video yalnız bellekte (IOSurface → VideoToolbox → soket) dolaşıyor. Koddan doğrulanan yazmalar:
  - `~/Library/Logs/MateBridge/host.log`: `RotatingLogFile`, 10 MB × 5 dosya, en çok 50 MB yer tutar. Bugün dosyalar yoğun günlerde ~1,5–3 saatte bir dönüyor, yani günde en çok ~50–100 MB yazma [ölçüm, dosya zamanları]. Bu yılda ~20–40 GB eder, SSD'lerin yüzlerce TB'lık yazma ömrünün yanında önemsiz [tahmin].
  - `latency.csv`: yalnız `MATEBRIDGE_LAT_TRACE=1` ile açılır, 8 MB × 2.
  - Tablet: loglar yalnız `logcat`'e (RAM halkası) gidiyor. `PaceTrace` bellekte bir halka, varsayılan kapalı, yalnız istenince dosyaya dökülüyor.
  - Not: `docs/LOGGING.md` tablette `logs/client.log` dosyası olduğunu söylüyor, ama kodda bu dosyayı yazan bir yer bulunamadı. Belgeyle kod uyuşmuyor, *Açık sorular*'a not.
- **Sürekli açık kalma:** Mac'in `sleep 0` / `displaysleep 0` ayarı kullanıcının kendi ayarı (NOTES 10-02, bugün de aynı). Oturum açıkken MateBridge da boşta uykuyu engelliyor. Mac mini boşta ~4–5 W civarı (M4 sınıfı, Apple) [kaynak]. Bu ömür sorunu değil, küçük bir enerji maliyeti.
- **Normal monitörle kıyas:** Mac açısından fark yok denecek kadar az. MateBridge yayın sırasında bir çekirdeğin ~%10'unu kullanıyor.

### 4.5 USB portu ve kablo

- USB-C konnektörü ~10.000 takıp çıkarma için tasarlanmıştır [kaynak]. Günde iki kez takıp çıkarmak bunun on yılda ~7.000'ine ulaşır. Asıl risk takıp çıkarmak değil, **gerilim altındaki kablo**: kalem çizerken tablet hareket ediyor, kablo portta kaldıraç gibi çalışıyor. Açılı (L) bir uç ve kablonun masaya sabitlenmesi bunu azaltır.
- Bugünkü bağlantı USB 2.0 hızında (480 Mbit/s). Akış için yetiyor, keyframe'ler 9–12 ms sürüyor. USB 3 kablo yalnız dosya aktarımında fark yaratır (NOTES 10-03 açık madde).
- **Normal monitörle kıyas:** monitör kablosu bir kez takılır ve yerinden oynamaz. Tablette port daha çok yıpranır.

### 4.6 Ömür özeti

| Risk | Normal monitör | MateBridge + MatePad | Ağırlık |
|---|---|---|---|
| Ekran yanması | LCD: yok. OLED: var, korumaları hazır. | Var. Tandem panel ve koyu mod yardımcı. Piksel kaydırma yok, **boşta ekran kapanmıyor**. | **Yüksek, önlenebilir** |
| Pil yıpranması | Yok | Var. Akıllı Şarj %80'de tutuyor gibi; sıcaklık önemli. | Orta |
| Isı | Düşük | Oyunda SoC ~40 °C, uzun süre ölçülmedi | Orta-düşük |
| Mac (SSD, kodlayıcı) | Yok | Önemsiz (≤50 MB log, kare başına yazma yok) | Önemsiz |
| Port / kablo | Önemsiz | Takıp çıkarma ve gerilim | Düşük |

## 5. Öneriler (değer / emek sırasıyla)

### 5.1 Bugün yapılabilecek ayarlar (kart gerekmez, kullanıcı kendisi yapar)

1. **Masadan kalkınca tablet ekranını güç tuşuyla kapat.** Bu tek alışkanlık bugünkü "boşta kimse kapatmıyor" açığını kapatır. Oturum BYE ile biter, Mac kendi ayarına göre uyur, dönünce tablet Mac'i uyandırır (T-128..T-134 zinciri). Emek: sıfır. Değer: en yüksek.
2. **Dock'u otomatik gizle:** Sistem Ayarları → Masaüstü ve Dock → "Dock'u otomatik olarak gizle ve göster". İsteğe bağlı olarak menü çubuğu da otomatik gizlenebilir ("Menü çubuğunu otomatik olarak gizle ve göster"; macOS sürümüne göre Denetim Merkezi ya da Menü Çubuğu bölümünde). Bu kullanışlılıktan biraz götürür, karar kullanıcının.
3. **macOS ekran koruyucusunu kısa tut:** Kilit Ekranı → "Etkin değilken ekran koruyucuyu başlat" 5–10 dk. Oturum açıkken MateBridge ekran uykusunu engellediği için kalan tek otomatik koruma bu. Bir kez denenip tablette gerçekten başladığı görülmeli.
4. **Akıllı Şarj açık kalsın.** HarmonyOS 4.3.1 güncellemesi gelince Ayarlar → Pil → Pil sağlığı → **Özel şarj sınırı %70** (Huawei'nin "uzun süre şarjda" önerisi).
5. **Parlaklık:** otomatik parlaklık açık kalsın. Elle %70–100'e çekip uzun süre öyle bırakılmasın. Koyu mod zaten açık. Koyu bir duvar kâğıdı da az da olsa yardımcı olur.
6. **Kablo:** açılı uçlu bir kablo kullanıp kabloyu masaya sabitlemek, portu çizim sırasındaki kaldıraç etkisinden korur.

### 5.2 MateBridge için özellik fikirleri

| # | Fikir | Değer | Emek / risk | Gerekenler |
|---|---|---|---|---|
| A | **Boşta karartma / kapatma:** tablette N dk hiç yerel girdi yoksa önce pencere parlaklığı düşürülür (`WindowManager.LayoutParams.screenBrightness`), sonra `FLAG_KEEP_SCREEN_ON` kaldırılır ve tabletin kendi zaman aşımı devreye girer. Böylece T-128'in varsayımı gerçek olur, Mac de kendi ayarına göre uyur. Uyandıran ilk dokunuş Mac'e tıklama olarak gitmemeli. Kararma anında basılı girdi olmadığı garanti edilmeli (release-all kuralı). | **Yüksek** (yanma, pil, enerji) | Küçük-orta, istemci tarafında. Girdi kuralına dokunur. | **Karar kaydı** (PLAN Aşama 4'teki "ekran uyumaz" maddesi ve T-128 gerekçesi değişir; N ve "ilk dokunuş yutulsun mu" kullanıcı seçimi) + istemci kartı |
| B | **Piksel kaydırma (pixel orbit):** video görünümü birkaç dakikada bir ±1–2 piksel kaydırılır. Kenardaki 1–2 piksel kırpılır ya da siyah kalır. Kalem ve dokunma koordinat dönüşümü aynı tek yerde kaydırmayı hesaba katar. Netlik bozulmaz, çünkü kaydırma tam pikselle yapılır ve ölçekleme yoktur. | Orta (yalnız keskin kenarları yayar; menü çubuğu bandının kendisini yok etmez) | Orta. Koordinat dönüşümüne dokunur, kalem hassasiyeti testi gerekir. | **Karar + kart.** Protokol değişmez. |
| C | **Uzun oturum sağlık kaydı:** T-194 dayanıklılık testine dakikada bir salt okunur `dumpsys thermalservice` (gövde sıcaklığı) ve `dumpsys battery` (seviye, durum, sıcaklık) örneği eklenir. | Orta (4.2 ve 4.3'teki belirsizlikleri kapatır) | Küçük, yalnız ölçüm | T-194 kartına madde, karar gerekmez |
| D | **Boşta yayın yükü:** Günlük mod varsayılanı 120 fps. Panel klavyeyle çalışırken 60 Hz'e iniyor, ama Mac 120 çizmeye devam ediyor (coverage audit, "düşük önem, enerji"). | Düşük | 0016 nedeniyle otomatik değişim yasak | Kart gerekmez. Kullanıcı yazı işinde Günlük 60 seçebilir. |

Önerilmeyenler:

- **Aşınmayı azaltmak için bit hızını düşürmek:** ne ekran ne pil ömrüne anlamlı bir etkisi var.
- **SSD için log kapatmak:** yazma miktarı zaten önemsiz.
- **Kablo yerine her gün Wi-Fi'ye geçmek:** pil döngüsü ekler, gecikmeyi artırır.

## Açık sorular

- `FLAG_KEEP_SCREEN_ON` (istemci) ile T-128'in "tabletin kendi zaman aşımı oturumu bitirir" gerekçesi çelişiyor. Bu bilinçli bir tercih mi, gözden kaçmış bir şey mi? Öneri A ile birlikte kullanıcıya sorulmalı.
- macOS 27'de oturum açıkken (assertion tutulurken) ekran koruyucu sanal ekranda başlıyor mu? Bir kez denenmeli.
- Tablet USB'den kaç W çekebiliyor? Uzun oyunda prizdeyken pil düşüyor mu?
- `docs/LOGGING.md` tablette `logs/client.log` diyor, kodda bu dosya yok. Belge düzeltmesi orkestratöre.

## Kaynaklar

Repo:

- `docs/PLAN.md` (§2 hazır çözümler, §4 mimari, Aşama 4 "ekran uyumaz")
- `docs/NOTES.md`:
  - 09-29: ilk görüntü ve Parsec karşılaştırması
  - 10-01: Wi-Fi ve BSD soket
  - 10-02 ~09:20: gecikme dökümü
  - 10-02 ~13:45 ve ~14:45: uyku
  - 10-02 ~21:30, 10-02 ~22:45, 10-02 ~23:40 ve 10-03 ~00:10: CPU, sıcaklık, GPU
  - 10-04: decoder A/B
  - 10-04 ~15:45: T-188 renk
- `docs/decisions/0010`, `0016`, `0029`, `0030`
- `backlog/tasks/T-128-host-sleep-policy-wol-txt.md`, `T-222`, `T-226`
- `docs/research/2026-10-04-smoothness.md` §5 (algı eşikleri)
- Kod:
  - `client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt:380` (`FLAG_KEEP_SCREEN_ON`)
  - `host-mac/Sources/MateBridgeHost/Session/SystemPower.swift` (`DisplaySleepAssertion`)
  - `host-mac/Sources/MateBridgeCore/Session/RotatingLogFile.swift` (10 MB × 5)
  - `host-mac/Sources/MateBridgeHost/Video/LatencyCsv.swift` (8 MB × 2)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/video/PaceTrace.kt` (RAM halkası)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt` (istatistik katmanı varsayılan kapalı)

Bugünkü salt okunur okumalar (2026-10-04 ~16:00):

- Tablet: `dumpsys battery`, `dumpsys display` (parlaklık, otomatik), `dumpsys thermalservice`.
- Mac: `pmset -g`, `pmset -g assertions`, `defaults read` (Dock, menü çubuğu, görünüm), `~/Library/Logs/MateBridge/` dosya boyut ve zamanları.

Web:

- VESA, DSC: https://vesa.org/vesa-display-compression-codecs/
- RTINGS, monitör input lag yöntemi: https://www.rtings.com/monitor/tests/inputs/input-lag
- RTINGS 10.000 saat OLED testi (özet): https://www.kitguru.net/peripherals/monitors/joao-silva/test-shows-modern-oleds-match-older-panels-in-burn-in-resistance-at-higher-brightness/ ve https://tftcentral.co.uk/articles/oled-and-qd-oled-image-retention-and-burn-in-longevity-testing
- OLED masaüstü kullanımında risk ve piksel kaydırma (genel rehber, ikincil kaynak): https://us.ktcplay.com/blogs/technology-hub/oled-monitor-burn-in-taskbar
- Huawei tandem OLED "3× ömür" (üretici iddiası): https://www.oled-info.com/huawei-matepad-pro-122-2024 ve https://www.androidpolice.com/huawei-matepad-pro-2024-tandem-oled/
- Huawei Akıllı Şarj: https://consumer.huawei.com/en/support/content/en-us00772869/
- Huawei Özel şarj sınırı (HarmonyOS 4.3.1+): https://consumer.huawei.com/en/support/content/en-us15851192/
- Battery University BU-808 (sıcaklık ve şarj seviyesine göre kapasite kaybı): https://www.batteryuniversity.com/article/bu-808-how-to-prolong-lithium-based-batteries
- Apple Sidecar: https://support.apple.com/en-us/102597
- DisplayLink'in macOS'te ekran yakalama izni: https://support.displaylink.com/knowledgebase/articles/1932214-displaylink-manager-app-for-macos-introduction-in ve https://kb.plugable.com/docking-stations/why-does-macos-say-displaylink-manager-is-capturing-your-screen
- Tablet ve telefonlarda USB-C görüntü (DP Alt Mode yalnız çıkış, UVC yakalama kartı yolu): https://us.ktcplay.com/blogs/support-tips/usb-c-display-connectivity-tablets-smartphones
- Ekran uykusu assertion'ları ekran koruyucuyu engellemiyor: https://developer.apple.com/forums/thread/26776
- Mac mini güç tüketimi: https://support.apple.com/en-us/103253
- 27" 4K monitör gücü (Dell U2720Q örneği, ikincil kaynak): https://bestpcmonitor.com/how-many-watts-does-a-27-inch-monitor-use/
- USB-C 10.000 takma döngüsü: https://en.wikipedia.org/wiki/USB-C
