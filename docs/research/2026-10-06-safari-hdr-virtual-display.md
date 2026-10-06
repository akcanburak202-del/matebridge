# Safari/YouTube HDR sanal ekranımızda neden açılmıyor (2026-10-06)

Soru: HDR sanal ekran açıkken (`CGVirtualDisplay`, `transferFunction=1`; Ekranlar'da "Yüksek Dinamik Aralık" anahtarı açık; `NSScreen` adı "MateBridge", `CGDirectDisplayID` 111; EDR potansiyeli ve güncel değer 5,0) Safari/YouTube HDR seçeneği sunmuyor. WebKit'in `screenSupportsHighDynamicRange` kararını veren MediaToolbox `MTShouldPlayHDRVideo([111])` **false** dönüyor. Hangi koşul başarısız, nasıl geçer, diğer tarayıcılar neye bakıyor?

Yöntem: bu Mac'te salt okuma.
- Kendi küçük sürecimizde `lldb` ile MediaToolbox disassembly'si ve stub → GOT çözümü.
- Aynı dahili işlevleri (SkyLight/CoreGraphics) display 111 için doğrudan sorgulama.
- `SidecarDisplayAgent` disassembly'si (`llvm-objdump`, statik `lldb` okuması).
- WebKit, Chromium ve Firefox kaynakları; web.

Ekran kurulmadı, ekran ayarı değiştirilmedi, pencere açılmadı, host çalıştırılmadı, tablete dokunulmadı.

Kanıt etiketleri (önceki HDR raporlarıyla aynı):
- **[Mac]**: bu Mac'te okundu ya da ölçüldü (Mac mini M6, `hw.model=Mac18,5`, macOS 27.0.1, 26A434).
- **[Repo]**: bu depodaki kod ya da belge.
- **[Kaynak]**: birincil kaynak (Apple/WebKit/Chromium/Mozilla kaynak kodu ya da belgesi).
- **[İddia]**: üçüncü taraf beyanı, doğrulanmadı.
- **[Tahmin]**: çıkarım.

## Özet

- **Başarısız koşul tek: ekranın renk alanı "geniş gamut" değil.**
  - `MTShouldPlayHDRVideo` dahili olmayan (harici) bir ekran için `CGColorSpaceIsWideGamutRGB(SLDisplayCopyColorSpace(id))` şartı arıyor.
  - Bizim ekranın ICC profilindeki primerler **sRGB/Rec.709**, çünkü descriptor'a primer vermiyoruz ve varsayılan 709. Sonuç `wide=0`, dolayısıyla SDR.
  - Diğer bütün koşullar geçiyor: boşluk 5,0 > 1, cihaz HDR'ye izinli, harici panel HDR'ye izinli, Catalyst değil, AC güçte.
- **Apple'ın Sidecar'ı descriptor'a her zaman Display P3 primerleri veriyor:** kırmızı 0,68/0,32, yeşil 0,265/0,69, mavi 0,15/0,06, beyaz 0,3127/0,329. Biz vermiyoruz.
  - **[Mac]** Aynı ICC'de yalnız primerleri P3 yapınca `CGColorSpaceIsWideGamutRGB` true dönüyor.
- **Önerilen düzeltme:** `VirtualDisplay` içinde, HDR (`tf=1`) kurulurken descriptor'a P3 primerleri vermek (geliştirici anahtarı ile başlar). `isReference`, EOTF değeri, EDID ya da ürün kimliği bu kararı **etkilemiyor**.
- **Diğer tarayıcılar:**
  - Chrome ve Firefox `MTShouldPlayHDRVideo` kullanmıyor; `NSScreen` EDR potansiyeline (> 1) bakıyor. Firefox ayrıca piksel derinliği > 24 şartı arıyor.
  - Bizim ekran ikisine göre de bugün HDR sayılır [Kaynak + Mac]. Chrome kurulu değil, YouTube'da uçtan uca denenmedi.

## 1. `MTShouldPlayHDRVideo` neye bakıyor?

### 1a. Çağrı zinciri ([Mac], `lldb` disassembly, stub'lar GOT üzerinden adlandırıldı)

```
MTShouldPlayHDRVideo(displays):
  if batteryGate() → false          // optimizeVideoStreamingOnBattery && güç kaynağı != "AC Power"
  FPSupport_GetCurrentDisplayModeVideoRangeAndSizeAndFrameRate(displays, &range, …)
  return range > 1                  // 1 = SDR, 2 = HLG, 3 = HDR10, 4 = DoVi, 5 = ?
```

- `batteryGate`:
  - `.GlobalPreferences` içindeki `com.apple.coremedia.optimizeVideoStreamingOnBattery` tercihini okur (`CFPreferencesCopyValue`).
  - `IOPSCopyPowerSourcesInfo` + `IOPSGetProvidingPowerSourceType` ile `"AC Power"` karşılaştırır.
  - Mac mini her zaman AC'de olduğu için geçer.
- `FPSupport_GetCurrentDisplayModeVideoRange…` şu adımları izler:
  - `SLGetActiveDisplayList` ile etkin ekranları alır ve listede verilen kimliği arar (`CFArrayContainsValue`).
  - Her eşleşen ekran için iç işlev `fpSupport_GetVideoRangeForCoreDisplayWithPreference(id, 1, 0)` çağrılır.
  - Ayrıca `SLDisplayCopyDisplayMode` ile boyut ve tazeleme hızını toplar. Bunlar karara girmez.

### 1b. Ekran başına karar (`fpSupport_GetVideoRangeForCoreDisplayWithPreference`)

İşlev bir tanı satırı basıyor (yalnız iç log açıkken):

> `<<<< Alt >>>> %s: displayID %x reported potentialHeadRoom=%g wideColorSupported=%s marz=%s almd=%s deviceAllowsHDR=%s isBuiltinPanel=%s externalPanel=%s prefersHDR10=%s`

Girdiler ve kaynakları:

| Alan | Nereden | Display 111 [Mac] |
|---|---|---|
| `potentialHeadRoom` | `SLSDisplayGetPotentialHeadroom(id)` (float) | **5,000** |
| `prefersHDR10` | `SLSDisplayGetPreferHDR10(id)` | 1 |
| `isBuiltinPanel` | `SLDisplayIsBuiltin(id)` | 0 |
| `wideColorSupported` | `CGColorSpaceIsWideGamutRGB(SLDisplayCopyColorSpace(id))` | **0** ← başarısız |
| `marz` | `_CFMZEnabled()` (Mac Catalyst) | 0 |
| `almd` | iOS-uygulaması-Mac'te bayrağı + `HDR_iOSAppOnMac` özellik bayrağı | 0 |
| `deviceAllowsHDR` | model tablosu (`hw.model` → 17 satır + varsayılan), bir kez yüklenir | 1 (varsayılan satır "ASDevices") |
| `externalPanel` | aynı tablodan "harici panelde HDR'ye izin" | 1 |

Karar mantığı (disassembly'den, sadeleştirilmiş):

```
result = (prefersHDR10 && arg1) ? 3 : 5
if !deviceAllowsHDR                         → 1 (SDR)
if marz && <Catalyst kısıtı>                → 1
if potentialHeadRoom <= 1.0                 → 1
if isBuiltinPanel                           → result
if externalPanel && wideColorSupported      → result
else                                        → 1 (SDR)
```

**[Mac]** Display 111 son satıra düşüyor: harici, boşluk var ama renk alanı geniş değil.
- `FPSupport_GetVideoRangeForCoreDisplay(111) = 1`.
- `MTShouldPlayHDRVideo([111]) = 0`.
- `AVPlayer preferredVideoRangeForDisplays:[111] = AVVideoRangeSDR`.
- `AVPlayer.eligibleForHDRPlayback = false`.

Kontrol edilmeyenler:
- Tepe parlaklık (nit). Yalnız boşluk değeri kullanılıyor.
- `isReference`, EOTF ya da `transferFunction` değeri (doğrudan).
- AirPlay ya da Sidecar türü, EDID, ürün ya da satıcı kimliği.
- Termal durum. WebKit ayrıca kendi tarafında termal kısıt uyguluyor, aşağıda.

### 1c. Ekranın renk alanı ([Mac])

- `SLDisplayCopyColorSpace(111)`: adsız ICC tabanlı profil (3368 bayt, `desc = "Display"`, `mmod` satıcı/ürün 0x4D42/0x0001).
  - Primerler (D50'ye uyarlanmış XYZ'den xy): kırmızı 0,6484/0,3308, yeşil 0,3212/0,5979, mavi 0,1559/0,0661.
  - Bunlar sRGB'nin D50 uyarlanmış değerleri. Beyaz noktası D65.
- Boş bir `CGVirtualDisplayDescriptor`'ın varsayılanı: `redPrimary` (0,64, 0,33), `greenPrimary` (0,30, 0,60), `bluePrimary` (0,15, 0,06), `whitePoint` (0,312727, 0,329023). Bunlar `displayInfo` sözlüğüne `DisplayRedPointX` … olarak da yansıyor. Yani Rec.709.
- `NSScreen`: `canRepresent(.p3) = false`. Bu, WebKit'in `color-gamut: p3` sorgusu için de `false` demek (aşağıda).
- **Doğrulama:** display 111'in ICC'sinin kopyasında yalnız `rXYZ/gXYZ/bXYZ` etiketleri P3'ün D50 değerleriyle değiştirildi ve `CGColorSpace(iccData:)` ile okundu.
  - Orijinal: `isWideGamutRGB = false`; P3'lü kopya: `true`.
  - Adlandırılmış alanlar: `sRGB` false; `displayP3`, `itur_2020`, `dcip3`, `adobeRGB1998`, `extendedSRGB` true.
  - Not: `CGColorSpace(calibratedRGB…)` ile kurulan alanlar primerden bağımsız olarak false dönüyor. İşlev ICC tabanlı alanlara bakıyor. Ekranın alanı ICC tabanlı olduğu için bu sorun değil.

## 2. Hangi `CGVirtualDisplay` alanı geçirir?

### 2a. Bugün ne veriyoruz ([Repo] `host-mac/Sources/MateBridgeHost/VirtualDisplay.swift`)

- Descriptor: `name`, `maxPixelsWide/High`, `sizeInMillimeters` (264 dpi), `vendorID 0x4D42`, `productID 0x0001`, `serialNum 1`, `queue`.
  - **Primer yok**, dolayısıyla varsayılan Rec.709.
- Settings: `hiDPI`, `modes`. `isReference` yok, `rotation` yok.
- Mode: `tf=1` ise `initWithWidth:height:refreshRate:transferFunction:`, değilse 3 argümanlı başlatıcı.

### 2b. Apple Sidecar ne veriyor ([Mac], `/usr/libexec/SidecarDisplayAgent` arm64e)

- `0x1000312ac…0x10003130c` arasında, sırayla:
  - `setSizeInMillimeters:` (25,4 / dpi ile hesaplanmış)
  - `setRedPrimary:(0.68, 0.32)`
  - `setGreenPrimary:(0.265, 0.69)`
  - `setBluePrimary:(0.15, 0.06)`
  - `setWhitePoint:(0.3127, 0.329)`
  - Sabitler `__const` içinde `0x10009da20…0x10009da58` adresinde okundu.
- Bu, DCI-P3 primerleri + D65, yani **Display P3**. Primerler koşulsuz bir blokta, tüm Sidecar ekranlarında veriliyor gibi [Tahmin: dallanma ayrıntılı izlenmedi].
- `setIsReference:` aynı işlevde, daha sonra (`0x10003153c`, `w2 = 1`), ardından 60 Hz'lik `tf` başlatıcısı (2026-10-04 raporu).

### 2c. Alanların karara etkisi

| Alan (yalnız `VirtualDisplay` içinde) | `MTShouldPlayHDRVideo`'ya etkisi | Not |
|---|---|---|
| **`red/green/bluePrimary` + `whitePoint` = Display P3** | **Evet: `wideColorSupported` 0 → 1** [Mac, ICC denemesiyle; canlı ekranda denenmedi] | Sidecar deseni. Önerilen. |
| Primerler = BT.2020 (0,708/0,292, 0,170/0,797, 0,131/0,046) | Evet (geniş gamut) [Tahmin: ICC benzeri] | Panel P3; 2020 abartı. Ayrıca masaüstü birleştirmesi 2020 uzayında yapılır. Önerilmez. |
| `isReference = 1` | Hayır (karar kodunda okunmuyor) | Parlaklık ya da ön ayar davranışını değiştirebilir; ayrı konu (imleç raporu aday E). |
| `transferFunction` başka değer (2/3) | Doğrudan hayır | Boşluk zaten 5,0. Değerler bilinmiyor. |
| Maks. nit / HDR modu anahtarı | Böyle bir alan yok | `CGVirtualDisplay*`'de yok. `kFigVirtualDisplayHDRMode_*` FigVirtualDisplay'e (AirPlay alıcı yolu) ait, bu yola girmiyor. |
| `displayInfo` / `setDisplayInfoValue:forKey:` | Dolaylı | Primerler `DisplayRedPointX…` anahtarlarıyla buraya yansıyor. Doğrudan anahtar yazmak yerine setter kullanılmalı. |
| `vendorID` / `productID` / EDID hileleri | Hayır | Karar `hw.model` tablosuna ve `SLDisplayIsBuiltin`'e bakıyor, ekran kimliğine bakmıyor. Dahili panel taklidi mümkün değil ve istenmez. |

- **[Kaynak]** Sanal ekran üretim belgesi (`CDVirtualDisplayCreate…` log biçimi) primerleri ekran kurulurken alıyor: `rp(%lf,%lf) gp(%lf,%lf) bp(%lf,%lf) wp(%lf,%lf)` (dyld cache dizgisi). Yani primerler yalnız descriptor'da, `initWithDescriptor:` anında verilebilir. `applySettings:` ile sonradan değişmez [Tahmin].
- **[İddia]** Vibepollo #539 `tf=1` ekranı "5x EDR headroom and a Display P3 gamut" diye tarif ediyor. P3'ü primerle mi verdikleri belirtilmemiş. Bizde `tf=1` tek başına P3 vermiyor [Mac].
- **[İddia]** BetterDisplay'in sanal ekran HDR SSS'i Display P3 profili öneriyor (https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/).
- **[İddia]** MacRumors forumunda kullanıcılar: harici ekranın renk profili ekranın varsayılanında kalırsa Safari YouTube'da HDR'yi görmüyor, Display P3 ya da Rec.2020 seçilince görüyor (https://forums.macrumors.com/threads/youtube-no-longer-in-hdr.2323130/page-11). Bizim bulgumuzla birebir aynı mekanizma.

### 2d. Yan etkiler (P3 primerleri)

- **[Repo]** Yakalama renk alanını açıkça seçiyor: SDR'de `colorSpaceName = sRGB` + 709 matris, HDR10'da `itur_2100_PQ` + 2020 matris (`ScreenCapture.swift` 74–81. satırlar). SCK ekran uzayından hedef uzaya dönüştürdüğü için teldeki anlam değişmez.
- **[Tahmin]** Kazanç: HDR10 akışta masaüstü birleştirmesi bugün sRGB gamutunda. Yani BT.2020 PQ akış yalnız sRGB renk taşıyor. P3 ile tablet panelinin P3 modunu (`Current color mode: DISPLAY_P3`, 2026-10-04 raporu) dolduran renkler akışa girer.
- **[Tahmin]** Risk:
  - SDR akışta P3 ekran + sRGB yakalama fazladan bir renk eşleme adımı demek (GPU, muhtemelen ihmal edilebilir).
  - Renk etiketi olmayan eski içerik ekran uzayında yorumlanırsa doygunluk biraz değişebilir.
  - Bu yüzden ilk adımda yalnız `tf=1` (HDR10) ekranında açılmalı.
- **[Tahmin]** ColorSync ekran profilini ekran UUID'sine (satıcı/ürün/seri) bağlar. Primerler değişince sistem yeni "Display" profili üretmeli. Kullanıcı elle profil atadıysa o öncelikli olur ve primerler görünmeyebilir. Kontrol için 1c'deki sorgu yeniden çalıştırılır.
- **[Repo]** `DisplayReuse` bugün modu `transfer` ile karşılaştırıyor (`VirtualDisplay.mode`). Primerler `tf=1`'e bağlanırsa ayrı bir anahtar gerekmez. Ayrı bir anahtar olursa yeniden kullanım karşılaştırmasına eklenmeli (karar 0020).

### 2e. WebKit tarafında ek koşullar ([Kaynak] `Source/WebCore/platform/mac/PlatformScreenMac.mm`)

- `collectHDRStateForDisplay`: varsa önce `[AVPlayer preferredVideoRangeForDisplays:@[id]]`, yoksa `MTShouldPlayHDRVideo(@[id])`. İkisi de aynı FPSupport yolundan geçiyor ve bizde SDR döndürüyor [Mac].
- Termal kısıt açıksa (`ThermalMitigationNotifier`) HDR kapatılıyor.
- `color-gamut: p3` için `screenSupportsExtendedColor`, yani `canRepresentDisplayGamut:NSDisplayGamutP3`. Bugün `false` [Mac]. P3 primerleri bunu da açmalı [Tahmin].
- Ekran özellikleri UI sürecinde toplanıp önbelleğe alınıyor. **[İddia]** Apple forum 746549: Safari sayfa yenilemede HDR bilgisini güncellemiyor, yeni sekme gerekiyor (https://developer.apple.com/forums/thread/746549). Deneyde Safari yeniden başlatılmalı ya da yeni sekme açılmalı.
- YouTube'un kendi kontrolü (`dynamic-range: high`, codec desteği) bu iki sorgunun üstüne biner [Tahmin]. M6'da VP9 Profile 2 ve AV1 çözme var.

## 3. Diğer tarayıcılar

- **Chrome [Kaynak]** `ui/display/mac/screen_mac.mm`:
  - `enable_hdr = screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.f` (yalnız Intel'de dahili panel ≤ 2 ise kapalı).
  - Renk alanı ICC'den alınıyor ama HDR kararına girmiyor.
  - `MTShouldPlayHDRVideo` kullanmıyor (GitHub kod aramasında yalnız WebKit, Darling ve SDK `.tbd` çıkıyor).
  - Bizim ekran (EDR potansiyeli 5,0) Chrome'a göre **bugün HDR** [Mac + Kaynak]. Chrome kurulu değil, YouTube'da doğrulanmadı.
  - https://source.chromium.org/chromium/chromium/src/+/main:ui/display/mac/screen_mac.mm
- **Firefox [Kaynak]** `widget/cocoa/ScreenHelperCocoa.mm`:
  - `isHDR = pixelDepth > 24 && maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0` (Big Sur+).
  - Bizim ekran: `supportedWindowDepths` en büyük 128 bpp, EDR 5,0, yani **HDR** [Mac].
  - Firefox 100 sürüm notu macOS'ta YouTube HDR'yi duyuruyor ve "pilde video akışını optimize et" ayarının kapalı olmasını istiyor. Bu, MediaToolbox'ın pil kapısıyla aynı ayar [Kaynak]. Firefox'un o ayarı nasıl okuduğu izlenmedi [Tahmin: sistem çözücüsü/AVFoundation tarafında etkili].
  - https://searchfox.org/mozilla-central/source/widget/cocoa/ScreenHelperCocoa.mm , https://www.mozilla.org/en-US/firefox/100.0/releasenotes/
- Sonuç: geniş gamut şartı **Safari'ye (WebKit/AVFoundation) özgü**. Chrome ve Firefox yalnız EDR boşluğuna bakıyor.

## 4. Deney listesi (orkestratör için; hepsi host tarafı, her biri ≤ 5 dk cihazda)

Ortak doğrulama (her deneyde):
- (a) Bu raporun salt okuma sorgusu ekran kurulduktan sonra çalıştırılır (ekran kurmaz, pencere açmaz). Beklenen: `wide=1`, `MTShould=1`, `AVPlayer … = AVVideoRangeHDR10`, `canRepresent(.p3) = true`.
- (b) Safari tamamen kapatılıp açılır, yeni sekmede bir YouTube HDR videosu açılır. Dişli menüsünde "… HDR" görünmeli.
- (c) SDR masaüstü renkleri tablette gözle karşılaştırılır (önce/sonra).

| Sıra | Deney | Değişiklik | Başarı olasılığı | Risk |
|---|---|---|---|---|
| 1 | **`MATEBRIDGE_VD_PRIMARIES=p3`** (ya da doğrudan: `tf=1` iken P3) | Yalnız `VirtualDisplay.swift`: `initWithDescriptor:` öncesi `setRedPrimary:(0.68,0.32)`, `setGreenPrimary:(0.265,0.69)`, `setBluePrimary:(0.15,0.06)`, `setWhitePoint:(0.3127,0.329)` (KVC `NSValue(point:)` ya da IMP). Ayrıştırıcı `MateBridgeCore`'da (`VirtualDisplayTransfer` gibi), `ev=vd_transfer`'e `primaries=p3` alanı. | **Yüksek**: başarısız tek koşul bu; ICC denemesi ve Sidecar deseniyle tutarlı. | Düşük. Özel API sınırı korunur (tek dosya). Ekran yeniden kurulur (karar 0020 aralığı). Yakalama renk alanı açık, akış anlamı değişmez. SDR'de küçük renk farkı olasılığı [Tahmin] bu yüzden önce yalnız HDR. |
| 2 | Kod yok, elle: Sistem Ayarları → Ekranlar → MateBridge → Renk profili → "Display P3" (`tf=1` açıkken) | Kullanıcı ayarı (ColorSync, ekran UUID'sine kalıcı) | Orta-yüksek [Tahmin: `SLDisplayCopyColorSpace` atanmış profili döndürür; HDR ekranlarda profil menüsü gizlenmiş ya da ön ayara dönmüş olabilir] | Orta. Kalıcı ayar; deneyden sonra "Display" varsayılanına dönülmeli. Kullanıcı ayarına dokunduğu için kullanıcıya bırakılır, ajan yapmaz. Hızlı kanıt olarak 1'den önce yapılabilir. |
| 3 | 1 + `MATEBRIDGE_VD_REFERENCE=1` (Sidecar'ın tam deseni) | `setIsReference:YES` (yalnız `VirtualDisplay`) | Bu sorun için gereksiz (karar kodu okumuyor) | Orta. Etkisi ölçülmedi (SDR beyazı, ön ayar). Yalnız 1 başarısız olursa ya da imleç raporu E adayıyla birlikte. |
| 4 | Chrome ya da Firefox ile çapraz kontrol (P3'süz, bugünkü ekran) | Kod yok; tarayıcı kurulumu kullanıcı kararı | Yüksek [Kaynak: EDR > 1 yeterli] | Düşük. Uygulama kurmak kullanıcıya ait. Safari'ye özgü kapıyı uçtan uca kanıtlar, zorunlu değil. |
| 5 | Primerler BT.2020 | 1'deki değerler 2020 ile | Yüksek ama gereksiz | Orta. Masaüstü birleştirmesi panelden geniş uzayda yapılır; SDR'de renk eşleme kaybı. Önerilmez. |

Önerilmeyen: dahili panel taklidi, `hw.model` ya da `deviceAllowsHDR` tablosuna müdahale, `defaults write` ile MediaToolbox tercihleri (`optimizeVideoStreamingOnBattery` zaten etkisiz; Mac mini AC'de). Sistem geneli, kırılgan, gereksiz.

### Salt okuma sorgusu (deney (a) için)

C, `dlopen`/`dlsym`. Yalnız okur, ekran kurmaz, pencere açmaz. Bu rapor için `scratchpad`'te çalıştırıldı; depoya eklenmedi.

```c
// clang -framework CoreGraphics -framework CoreFoundation q.c -o q
float (*head)(uint32_t) = dlsym(sl, "SLSDisplayGetPotentialHeadroom");
bool  (*bi)(uint32_t)   = dlsym(sl, "SLDisplayIsBuiltin");
CGColorSpaceRef (*cs)(uint32_t) = dlsym(sl, "SLDisplayCopyColorSpace");
Boolean (*should)(CFArrayRef)   = dlsym(mt, "MTShouldPlayHDRVideo");
// her etkin ekran için: head(id), bi(id), CGColorSpaceIsWideGamutRGB(cs(id)), should(@[id])
```

Bugünkü çıktı [Mac]:
`id=111 vendor=0x4d42 product=0x1 headroom=5.000 preferHDR10=1 builtin=0 wide=0 MTShould=0 range=1`

## Kaynaklar

- WebKit `PlatformScreenMac.mm` (`collectHDRStateForDisplay`, `screenSupportsHighDynamicRange`, `screenSupportsExtendedColor`): https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/mac/PlatformScreenMac.mm
- WebKit `MediaToolboxSoftLink.h` (`MTShouldPlayHDRVideo(CFArrayRef displayList)`): https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/cocoa/MediaToolboxSoftLink.h
- Chromium `screen_mac.mm`: https://source.chromium.org/chromium/chromium/src/+/main:ui/display/mac/screen_mac.mm
- Firefox `ScreenHelperCocoa.mm`: https://searchfox.org/mozilla-central/source/widget/cocoa/ScreenHelperCocoa.mm
- Firefox 100 sürüm notları (macOS HDR video, pil ayarı): https://www.mozilla.org/en-US/firefox/100.0/releasenotes/
- Apple forum 746549 (Safari HDR bilgisini yenilemede güncellemiyor): https://developer.apple.com/forums/thread/746549
- MacRumors, "YouTube no longer in HDR" (renk profili geniş gamut olmalı): https://forums.macrumors.com/threads/youtube-no-longer-in-hdr.2323130/page-11
- Vibepollo PR #539: https://github.com/Nonary/Vibepollo/pull/539
- BetterDisplay sanal ekran HDR SSS: https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/
- Bu Mac: MediaToolbox (`MTShouldPlayHDRVideo`, `FPSupport_*`), SkyLight (`SLSDisplayGetPotentialHeadroom`, `SLSDisplayGetPreferHDR10`, `SLDisplayIsBuiltin`, `SLDisplayCopyColorSpace`), `/usr/libexec/SidecarDisplayAgent`, dyld shared cache dizgileri.
- Repo: `host-mac/Sources/MateBridgeHost/VirtualDisplay.swift`, `host-mac/Sources/MateBridgeCore/Video/VirtualDisplayTransfer.swift`, `host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift`; `docs/research/2026-10-04-hdr-feasibility.md`, `docs/research/2026-10-06-hdr-fullscreen-cursor.md`; karar 0020, 0032.
