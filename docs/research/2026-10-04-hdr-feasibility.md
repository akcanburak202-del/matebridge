# HDR fizibilite araştırması (2026-10-04, T-226)

Soru: MateBridge HDR akıtabilir mi (HDR sanal ekran → 10-bit HEVC → tablette HDR10/HLG)? Hangi halka engel, maliyet ne? Çıkış noktası: Resident Evil 4 ayarlarında HDR açılmıyor ("monitörünüzün HDR özelliği olduğundan emin olun"), oysa tablet HDR10 ve HLG destekliyor.

Yöntem: Mac'te salt okuma (ObjC runtime listesi, kendi sürecimizde disassembly, dyld shared cache dizgileri, `SidecarDisplayAgent` disassembly'si, VT yetenek sorgusu; ekran kurulmadı, pencere açılmadı, kodlayıcı oturumu açılmadı), tablette salt okuma (`dumpsys display`, `dumpsys SurfaceFlinger`, `dumpsys media.player`, `/vendor/etc/media_codecs.xml`, `getprop`) ve web. Deney gerektiren halkalar için `probes/hdr-probe/` yazıldı ama çalıştırılmadı.

Kanıt etiketleri:
- **[Mac]**: bu Mac'te (Mac mini M6, macOS 27.0.1, 26A434) okundu.
- **[Tablet]**: MatePad'den okundu (Kirin T92A, HarmonyOS 4.3, API 31).
- **[Kaynak]**: birincil kaynak (Apple/AOSP belgesi, kaynak kod).
- **[İddia]**: üçüncü taraf beyanı, doğrulanmadı.
- **[Tahmin]**: çıkarım.

## Özet

| # | Halka | Cevap | Engel mi? |
|---|---|---|---|
| 1 | Sanal ekran HDR bildirebilir mi | **Büyük olasılıkla evet** (macOS 27 özel API'si; Apple'ın Sidecar'ı kullanıyor). Değer anlamı ve RE4/GameHub'ın bunu görmesi **bilinmiyor** → prob + geliştirici anahtarı | Hayır (doğrulanacak) |
| 2 | SCK HDR yakalama | **Evet** (API ve preset'ler var; 10-bit 4:2:0 PQ BT.2020 hazır). Sanal ekranda gerçek davranış → prob | Hayır |
| 3 | VT HEVC Main10 + PQ/HLG + HDR metadata | **Evet** (her iki kodlayıcı da destekliyor). Hızlı profilde 120 fps süresi **ölçülmedi** → prob | Hayır (120 fps'te risk) |
| 4 | Tel biçimi | Renk kodları zaten `STREAM_CONFIG`'te. **Küçük bir ekleme gerekir**: istemcinin HDR isteği/yeteneği (STREAM_PREFS), isteğe bağlı HDR metadata | Hayır |
| 5 | HiSilicon çözme + HarmonyOS HDR sunumu | Decoder **Main10 ve Main10HDR10 bildiriyor**, HWC **hdr10=true hlg=true**. Üçüncü taraf `SurfaceView`'ın gerçekten HDR moduna geçtiği **bilinmiyor** → Android probu | Bilinmiyor (asıl açık risk) |
| 6 | SDR içerik HDR akışta | API 31'de SDR karartma yok; masaüstü beyazı mutlak ~140–203 nit'e sabitlenir, parlaklık ayarı etkisi bilinmiyor → **HDR yalnız Oyun modunda ve isteğe bağlı** | Tasarım kararı |

**Sonuç:** Kesin bir engel bulunmadı. Mac tarafındaki üç halka macOS 27'de mevcut. Açık riskler şunlar:
- HarmonyOS 4.3'ün üçüncü taraf bir video katmanını HDR olarak sunup sunmadığı (halka 5).
- GameHub (Wine/D3DMetal) üzerinden çalışan RE4'ün HDR ekranı görüp görmediği (halka 1'in oyun tarafı; D3DMetal'de bilinen bir hata var).

İkisi de ucuz deneylerle cevaplanır. Önerilen sıra ve maliyet aşağıda.

## 1. Sanal ekran HDR bildirebilir mi?

**Bulgular:**
- **[Mac]** macOS 27'de runtime'daki sınıflar şunlar:
  - `CGVirtualDisplayMode`: yeni bir `-initWithWidth:height:refreshRate:transferFunction:` (son argüman `uint32`), `transferFunction` ve `setTransferFunction:`.
  - `CGVirtualDisplaySettings`: yeni `isReference` / `setIsReference:` ve `refreshDeadline`.
  - `CGVirtualDisplayDescriptor`: `red/green/bluePrimary`, `whitePoint`, `displayInfo` ve `setDisplayInfoValue:forKey:`.
  - Hiçbir sınıfta `hdr`, `maxLuminance` ya da `headroom` adlı bir özellik yok.

  Çıktı: `hdr-probe inspect` (bkz. Prob).
- **[Mac]** `-[CGVirtualDisplay applySettings:]` her modu bir sözlüğe çevirir: `CDVirtualDisplayModeWidth/Height/RefreshRate` ve `CDVirtualDisplayModeEOTF = transferFunction`.
  - SkyLight tarafında `SLVirtualDisplayMode` sınıfının `eotf` ve `options` alanları var (`SLVirtualDisplayModeEOTF`).
  - Yani `transferFunction` pencere sunucusuna giden bir **EOTF** seçicisidir.
  - Sayısal değerlerin adı ikili dosyada geçmiyor. **[Tahmin]** Değerler CTA-861 EOTF kodlarına benziyor olabilir (0 SDR, 1 "geleneksel HDR", 2 PQ, 3 HLG), ama bu doğrulanmadı.
- **[Mac]** Apple'ın kendi kullanımı: `/usr/libexec/SidecarDisplayAgent` (arm64e) `initWithWidth:height:refreshRate:transferFunction:` seçicisini çağırıyor.
  - Çağrıdan hemen önce `setIsReference:` ile `w2 = 1` var.
  - Çağrı `transferFunction = 1` (`mov w4, #0x1`) ve 60 Hz ile yapılıyor.
  - Normal Sidecar modları 3 argümanlı başlatıcıyı kullanıyor.
  - Aynı ikili dosyada `hdrMode`/`setHdr:` var; `hdrMode == 3` ise `setHdr:YES` çağrılıyor.
  - **[Kaynak]** Apple: "Reference Mode etkin bir iPad Sidecar ekranı olarak kullanılırsa EDR destekler" (macOS Ventura+, Apple silicon). https://developer.apple.com/videos/play/tech-talks/110337/
  - Sonuç: **`transferFunction = 1` Apple'ın kendi HDR/EDR sanal ekran yoludur.**
- **[Mac]** Dyld cache'te `FigVirtualDisplay` (AirPlay/ekran yansıtma) için `kFigVirtualDisplayHDRMode_HDR10/HLG/DoVi/SDR` ve `kFigVirtualDisplayUsage_AirPlayHDR` bulunuyor. Sistem uzak ekranlar için HDR modlarını tanıyor.
- **[İddia]** Vibepollo PR #539 (açık, 2026-10-02): "macOS 27's private CGVirtualDisplayMode takes a transfer function, and 1 makes the display HDR … 5x EDR headroom and a Display P3 gamut. The value is undocumented and was found by testing."
  - Test donanımı: MacBook Pro, macOS 27, iPad Pro'ya HDR masaüstü akışı.
  - https://github.com/Nonary/Vibepollo/pull/539
- **[Kaynak]** BetterDisplay v4.3.3 "HDR support for virtual screens (#5257)" ekledi. SSS'ye göre bu "extended-luminance, 16-bit modlar" demek, Display P3 profili öneriliyor ve yakalama uygulaması da HDR desteklemeli. Bayrağın adı verilmiyor.
  - https://github.com/waydabber/BetterDisplay/releases/tag/v4.3.3
  - https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/
- **[Mac]** Bugünkü "MateBridge" ekranı SDR: `maximumPotentialExtendedDynamicRangeColorComponentValue = 1.0`, `maxEDR = 1.0`, `wide=false`, `hdr=false`.
  - Ekran 3 argümanlı başlatıcıyla, primer verilmeden kuruluyor (`VirtualDisplay.swift`).
  - RE4'ün HDR'yi reddetmesi bununla tutarlı.

**Oyunlar HDR'yi neye bakarak açar?**
- **[Kaynak]** macOS'ta kural `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1`. Çizim `CAMetalLayer.wantsExtendedDynamicRangeContent` ile ve PQ/HLG ya da extended-linear renk alanıyla yapılır (WWDC21 10161).
- **[Tahmin]** RE4 burada GameHub (Wine/GPTK) üzerinden çalışıyor (smoothness raporu). Bu yüzden karar D3DMetal'in DXGI `IDXGIOutput6::GetDesc1().ColorSpace` cevabına bağlı.
  - **[Kaynak]** Apple forumunda D3DMetal'in harici HDR ekranlarda da SDR (`G22_NONE_P709`) döndürdüğü bildirilmiş (FB22330617), henüz çözülmemiş. https://developer.apple.com/forums/thread/820469
  - **Risk:** ekran HDR olsa bile RE4 (GameHub) HDR seçeneğini açmayabilir. Bu yalnız gerçek ekranla denenerek öğrenilir.

**Cevap:** Büyük olasılıkla evet. Doğrulanması gerekenler:
- (a) `tf=1` gerçekten `maxPotentialEDR > 1` veriyor mu, `isReference` gerekiyor mu, 2/3 değerleri ne yapıyor? → `hdr-probe vd --sweep`
- (b) RE4/GameHub görüyor mu? → MateBridge ekranını HDR kuran bir geliştirici anahtarı (aşağıda kart A). Prob ekranı tablette görünmediği için oyun orada denenemez.

## 2. Yakalama: ScreenCaptureKit HDR

- **[Kaynak, SDK başlığı]** `SCStreamConfiguration.captureDynamicRange`: `.SDR`, `.hdrLocalDisplay`, `.hdrCanonicalDisplay` (macOS 15+, yalnız Apple silicon).
  - HDR'de kayıt çıkışı (recording output) desteklenmiyor; bizim için önemsiz, çünkü biz `SCStreamOutput` kullanıyoruz.
  - WWDC24 10088: en az 10-bit ("10-bit YCbCr will be the best choice"); PQ ya da HLG. "Canonical" diğer HDR cihazlarla paylaşmak için optimize edilmiş. https://developer.apple.com/videos/play/wwdc2024/10088/
- **[Mac]** Preset değerleri macOS 27'de:

  | Preset | Piksel biçimi | Renk alanı | Matris |
  |---|---|---|---|
  | `captureHDRStreamLocalDisplay` | `xf44` | `DisplayP3_PQ` | 709 |
  | `captureHDRStreamCanonicalDisplay` | `xf44` | `DisplayP3_PQ` | 709 |
  | `captureHDRRecordingPreservedSDRHDR10` (macOS 26) | `x420` (10-bit 4:2:0 video range) | `ITUR_2100_PQ` | BT.2020 |

  **`x420` + BT.2100 PQ, HEVC Main10 4:2:0 için dönüşümsüz girdi** demek. Bugünkü 8-bit 4:2:0 hattının birebir 10-bit karşılığı.
- **[İddia]** Vibepollo #539: HDR sanal ekranın SCK HDR yakalaması "10-bit frames already in BT.2020 with PQ" veriyor; yakalanan karelerde SDR beyazı ~140 nit; tepe değer EDR boşluğu × 140 (en çok ~1600 nit).
- **[İddia]** Apple forum 815971: renk alanı verilince değerler 1.0'da kırpılmış, verilmeyince aşmış. Uygulamada bu ayrıca kontrol edilmeli. https://developer.apple.com/forums/thread/815971
- **[Tahmin]** SDR ekranda HDR yakalama anlamsız: boşluk yok, PQ yalnız SDR aralığını taşır. Ekranın HDR kurulması şart.
- Gecikme/bant:
  - **[Tahmin]** 10-bit yüzey 8-bit'in 2 katı bellek (2800×1840 x420 ≈ 15,5 MB/kare, 420f ≈ 7,7 MB).
  - GPU dönüşümü SCK içinde. Ek gecikme muhtemelen < 1 ms ama ölçülmedi. Prob kare sayısını ölçer, gecikmeyi ölçmez.

**Cevap:** Evet (API hazır). Sanal ekranda kare biçimi, kare hızı ve SDR beyaz seviyesi `hdr-probe vd --tf 1 --capture recording|canonical` ile ölçülür.

## 3. Kodlama: VideoToolbox HEVC Main10 + PQ/HLG

- **[Mac]** 2800×1840 HEVC için `VTCopySupportedPropertyDictionaryForEncoder` (oturum açmadan):
  - Varsayılan kodlayıcı (`ave.hevc`) ve LLRC kodlayıcısı (`hevc.rtvc`) ikisi de `HEVC_Main10_AutoLevel` destekliyor.
  - İkisi de `MasteringDisplayColorVolume`, `ContentLightLevelInfo`, `HDRMetadataInsertionMode`, `TransferFunction`, `ColorPrimaries` ve `YCbCrMatrix` anahtarlarını kabul ediyor.
- **[Kaynak]** MDCV 24 bayt, CLL 4 bayt, HEVC SEI düzeninde big-endian. `HDRMetadataInsertionMode = Auto` SEI'yi bit akışına yazar. Prob bu baytları üretir ve test eder (`HDRProbeCore`).
- **[Mac, repo]** T-047 tezgâhı (8-bit girdi, LLRC yolu, 2800×1840):
  - Main10: max 75 fps, 120 hedefte 93 fps, p50/p95/p99 9,3/15,1/16,4 ms.
  - Aynı yolda Main 8-bit: 88–104 fps, 9,4/10,7/13,3 ms.
  - Ürünün bugünkü **hızlı profilinde** (LLRC yok + `RealTime=false`, T-053'ten beri her fps'te varsayılan) 8-bit: 120 fps'te 5,8/7,3/10,2 ms. **Bu yolda Main10 hiç ölçülmedi.**
- **[İddia]** Sunshine #5814 (M4, 4K): LLRC ~55 fps'te tavan yapıyor, LLRC olmadan ~97 fps. Bizim T-047 bulgumuzla tutarlı.
- **[Tahmin]**
  - Oyun modu 0029 oyun ekranında (varsayılan 1848×1214, 2800×1840'ın ~%44'ü) 60 fps kodlar. Main10 orada rahat olmalı.
  - 2800×1840@120 Main10'da hızlı yol 120 fps'e yetmeyebilir.
  - HDR bu yüzden önce Oyun modunda (60 fps, oyun çözünürlüğü) düşünülmeli.

**Cevap:** Evet. Süre ölçümü `hdr-probe encode --path fast --transfer pq --fps 60|120` ile yapılır (akış kapalıyken, tek kodlayıcı var).

## 4. Tel biçimi

- **[Repo]** `STREAM_CONFIG` H.273 renk kodlarını zaten taşıyor (`color_primaries`, `transfer`, `matrix`, `full_range`).
  - HDR10 için: `primaries=9` (BT.2020), `transfer=16` (PQ; HLG `18`), `matrix=9`, `full_range=0` (`x420` video range).
  - İstemcinin `ColorMapping.kt` dosyası 16→`COLOR_TRANSFER_ST2084`, 18→`HLG`, 9→`COLOR_STANDARD_BT2020` eşlemesini **zaten yapıyor**.
- Bit derinliği ve profil SPS'te (`CODEC_CONFIG`) bulunuyor; decoder Main10'u SPS'ten seçer. VUI renk bilgisi VT tarafından yazılır (T-113'te SDR için doğrulandı).
- HDR10 statik metadata bit akışında SEI olarak gider (decoder okur).
  - **[Kaynak]** Moonlight-android ayrıca `KEY_HDR_STATIC_INFO` (25 bayt, little-endian) koyuyor; değerleri host kontrol kanalından alıyor.
  - Moonlight HDR'yi yalnız `Display.getHdrCapabilities()` HDR10 içeriyorsa **ve** decoder `HEVCProfileMain10HDR10` bildiriyorsa açıyor.
  - https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java
- **Eksik olan:** host'un istemcinin HDR isteyip isteyemeyeceğini bilmesi. Eski istemciye HDR akış gönderilmemeli: decoder ve ekran kontrolü istemcide.

**Öneri taslağı (yalnız öneri; protokolü orkestratör değiştirir):**
1. `STREAM_PREFS`'e isteğe bağlı grup: `dynamic_range u8` (`0` SDR, `1` HDR10, `2` HLG) + `reserved u8`.
   - Payload 12 (bugünkü) ya da en az 14 bayt olur; 13 bayt kısa payload sayılır.
   - İstemci `1`'i yalnız şu koşullarda gönderir: ekran HDR10 bildiriyor, decoder `Main10HDR10` bildiriyor, kullanıcı HDR'yi açmış.
2. `STREAM_CONFIG` HDR'de yukarıdaki H.273 kodlarını gönderir; istemci bunları uygulanan dinamik aralık olarak okur. Host HDR veremiyorsa SDR kodları gider ve istemci SDR'de kalır.
3. İsteğe bağlı (prob sonucuna göre): `STREAM_CONFIG`'e `max_cll u16`, `max_fall u16`, `mastering_max_nits u16` grubu. Böylece istemci `KEY_HDR_STATIC_INFO`'yu Moonlight gibi kurar. Probun `static_info=false` varyantı bunun gerekli olup olmadığını gösterir. Gerekmiyorsa eklenmez.
4. Fixture: `stream_prefs_hdr`, `stream_config_hdr10`. HDR geçişi yeni `config_id` ile olur (§3 adım 7). Sanal ekranın yeniden kurulması gerekebilir, bkz. karar 0020.

## 5. Çözme ve gösterim (tablet)

- **[Tablet]** `dumpsys media.player`'a göre `OMX.hisi.video.decoder.hevc` şunları bildiriyor:
  - Profiller: `Main` (1), **`Main10` (2)** ve **`Main10HDR10` (4096)**, her biri Level 5.1'e kadar. `Main10HDR10Plus` yok.
  - Renk biçimleri: `YUV420Flexible`, `YUV420SemiPlanar`, `0x7f000001`.
  - Moonlight'ın koşulu (Main10HDR10) sağlanıyor.
  - Level 5.1 sınırı 8-bit Main için de aynı ve 2800×1840@120 bugün zaten çalışıyor; yani sınır pratikte bağlayıcı değil.
  - Ölçülen hız tablosu (4K 71 fps) 8-bit içindir. **10-bit çözme süresi bilinmiyor.**
- **[Tablet]** `dumpsys display`:
  - `HdrCapabilities{mSupportedHdrTypes=[2, 3], mMaxLuminance=500.0, mMaxAverageLuminance=102.0, mMinLuminance=1.0}`
  - `userDisabledHdrTypes []`
  - `supportedColorModes [0, 7, 9]`
  - `mIsHdrLayerPresent=false` (şu an).
- **[Tablet]** `dumpsys SurfaceFlinger`:
  - `HWC Support: wideColorGamut=true hdr10plus=false hdr10=true hlg=true dv=false metadata=3`
  - `Current color mode: DISPLAY_P3`
  - Bugünkü MateBridge video katmanı `NV12`, dataspace `SRGB`, `DEVICE` (HWC katmanı), `HEBC`.
  - `getprop`: `hw_mc.display.hdr_brightness_support=true`, `hdr_gpu_support=true`.
- **[Kaynak]** AOSP:
  - HDR video için decoder `describeColorAspects`/`describeHDRColorInfo` ile HWC'ye bilgi geçirir.
  - SDR karartma ve ortak ton eşleme **Android 13**'te geldi. API 31'de SDR+HDR karışımı üreticiye kalmış.
  - https://source.android.com/docs/core/display/hdr
  - https://source.android.com/docs/core/display/mixed-sdr-hdr
- **[İddia]** Huawei'de üçüncü taraf HDR deneyimi zayıf belgelenmiş:
  - Moonlight'ın Huawei HDR desteği ayrı bir HarmonyOS NEXT uygulamasında (moonlight-harmony). Android yolu değil.
  - Flutter #179800: HarmonyOS 4 decoder'ı bazı BT.709 akışlarda `format_supported=YES` dediği halde hata vermiş.
- **Bilinmeyen (asıl risk):**
  - P010 + `BT2020_PQ` bir `SurfaceView` katmanında HarmonyOS 4.3 ekranı HDR moduna alıyor mu (`mIsHdrLayerPresent=true`, parlaklık artışı)?
  - Yoksa katmanı SDR'ye ton eşleyip mi gösteriyor?
  - Huawei'nin AI HDR / parlaklık politikası (`hdr_brightness_support`) uygulamaya göre değişiyor olabilir.
- Güç/ısı: **[Tahmin]** HDR modunda panel yerel tepe parlaklığa çıkar, güç ve ısı artar. Ölçülmeli (SoC sıcaklığı, pil).

**Cevap:** Decoder ve HWC yeterli görünüyor. Sunum `probes/hdr-probe/android` ile ölçülür: Mac probunun ürettiği HDR10/HLG klibi, SDR arayüz yaması yanında oynatılır ve SurfaceFlinger okunur.

## 6. SDR içerik HDR akışta

- Mac tarafı: HDR ekranda SDR uygulamalar referans beyazında çizilir.
  - Yakalamada bu ~140 nit (Vibepollo, [İddia]) ya da BT.2408'e göre 203 nit olabilir. Prob ölçer.
  - Masaüstü, yazılar ve menüler PQ akışta bu mutlak seviyeye sabitlenir.
- Tablet tarafı: **[Tahmin]** PQ mutlak bir eğri. API 31'de SDR karartma yok.
  - Parlaklık yüksekken masaüstü SDR akışa göre daha soluk, düşükken daha parlak görünebilir.
  - Arayüz katmanları (MateBridge'in kendi göstergeleri) SDR kalır. Ton farkı göze batabilir.
- HLG göreli (sahne referanslı) bir eğri. Panel parlaklığına daha iyi uyar, ama SCK HLG preset'i yok. PQ→HLG dönüşümü bir GPU geçişi gerektirir (ör. `VTPixelTransferSession`, doğrulanmadı). Prob bu yüzden HLG klibini de dener.
- Metin keskinliği: HDR 4:2:0 10-bit kalır. 4:4:4 ayrı konu, kapsam dışı.

**Cevap:** HDR yalnız **Oyun modunda ve isteğe bağlı** olmalı ("HDR: Kapalı / Açık", varsayılan Kapalı). Günlük ve Çizim SDR kalır. Kalem çizimi için HDR'nin faydası yok, maliyeti var (gecikme, enc süresi).

## Önerilen mimari (prob sonuçları olumluysa)

- **Biçim:** HDR10 (PQ, BT.2020, 10-bit 4:2:0 video range, HEVC Main10, SEI MDCV/CLL).
  - Gerekçe: SCK'nin HDR preset'leri PQ. `captureHDRRecordingPreservedSDRHDR10` doğrudan `x420`/BT.2100 PQ veriyor, dönüşüm yok.
  - VT metadata desteği tam. Moonlight'ın kanıtlanmış yolu da bu.
  - HLG yalnız tablette SDR beyazı PQ'da kötü çıkarsa yedek seçenek.
- **Akış:**
  1. Oyun modu + HDR açık: host oyun ekranını `transferFunction=1` ile kurar (gerekirse `isReference`, P3 primerleri). HDR açma/kapama ekranı yeniden kurmayı gerektirebilir; karar 0020'nin yaşam süresi kuralı içinde.
  2. SCK: `captureDynamicRange = .hdrCanonicalDisplay`, `pixelFormat = x420`, `colorSpaceName = itur_2100_PQ`, matris 2020.
  3. VT: `Main10_AutoLevel`, primaries/transfer/matrix 2020/PQ/2020, MDCV + CLL, `HDRMetadataInsertionMode = Auto`, bugünkü hızlı profil. Girdi etiketleri T-113'teki gibi yeniden yazılır (2020/PQ).
  4. İstemci: koşullar sağlanırsa (ekran HDR10, decoder Main10HDR10, kullanıcı açık) `STREAM_PREFS.dynamic_range=1` gönderir. `STREAM_CONFIG`'teki kodlarla decoder'ı kurar, gerekirse `KEY_HDR_STATIC_INFO` ekler. `ev=output_format` satırına `hdr_static_info` ve profil eklenir.
  5. Geri dönüş: herhangi bir halka reddederse (ekran kurulamıyor, SCK hata veriyor, decoder hata veriyor) host SDR'ye düşer ve `ev=hdr_fallback reason=` yazar.
- **Bant:** **[Tahmin]** Aynı kalite için %10–20 daha fazla bit. Oyun modu 60 Mbps, USB 2.0 (~35 MB/s ≈ 280 Mbps) ve Wi-Fi bütçesi içinde kalır.
- **Gecikme:**
  - Kodlama (2800×1840 Main10 hızlı yol) ölçülmedi. Oyun çözünürlüğünde ~+0–2 ms bekleniyor. **[Tahmin]**
  - 10-bit çözme (HiSilicon) ölçülmedi.
  - Yakalama tarafı muhtemelen ihmal edilebilir.

## Kart bölümlemesi ve kaba maliyet

| Kart | İş | Kim | Kaba maliyet |
|---|---|---|---|
| (prob) | `hdr-probe inspect` + `vd --sweep` + `vd --tf 1 --capture ...` (Mac, onaylı); `encode` (akış kapalı); Android probu (onaylı). Sonuçlar bu rapora ve NOTES'a | Orkestratör | ~0,5 gün, 3 kısa cihaz oturumu |
| A | Geliştirici anahtarı `MATEBRIDGE_VD_TRANSFER=<n>` (karar 0026): MateBridge ekranı `transferFunction` ile kurulur, **akış SDR kalır**. Kullanıcı RE4'te HDR seçeneğinin açılıp açılmadığına ve SDR yakalamanın HDR ekranda doğru göründüğüne bakar (T-188 sayfası) | mac-host-dev | ~0,5 gün + 1 cihaz testi |
| B | Karar kaydı: HDR10, yalnız Oyun modu, isteğe bağlı; protokol eki (STREAM_PREFS `dynamic_range`, gerekirse STREAM_CONFIG metadata grubu) + fixture'lar | Orkestratör | ~0,5 gün |
| C | Host: HDR ekran + SCK HDR + VT Main10 PQ + metadata + SDR'ye düşüş + `ev=` günlükleri + testler | mac-host-dev | ~1,5–2 gün |
| D | İstemci: yetenek kontrolü, `dynamic_range` isteği, decoder kurulumu (`KEY_HDR_STATIC_INFO`), Oyun modunda "HDR" anahtarı, günlükler, testler | android-client-dev | ~1–1,5 gün |
| E | Cihaz kabulü: RE4 HDR açık, test sayfası (SDR beyaz, rampa, 1000 nit yaması), enc/dec ms, SoC sıcaklığı, pil; Codex incelemesi (protokol) | Kullanıcı + orkestratör | ~1 gün |

Toplam: ajan işi ~4–5 gün, artı 3–4 cihaz oturumu. **A, prob 1. adımı olumluysa B–E'den önce yapılmalı.** RE4/GameHub HDR'yi görmüyorsa (D3DMetal hatası) asıl motivasyon düşer. O durumda B–E yalnız yerel macOS HDR içerik (HDR video, Metal oyunlar) için değer mi diye kullanıcıya sorulur.

## Uygulanamazsa neyin değişmesi gerekir

- `transferFunction=1` EDR vermezse: macOS 27'nin sonraki bir sürümü ya da kamuya açık bir API gerekir. BetterDisplay ve Vibepollo'nun yaptığı adımlar incelenir. Değer taraması (`--sweep`) ilk adımdır.
- HarmonyOS 4.3 üçüncü taraf `SurfaceView`'ı HDR sunmuyorsa iki yol kalır: HarmonyOS NEXT'e geçiş ya da Huawei'ye özel bir API. İkincisi HMS bağımlılığı demek ve karar kaydı ister. HLG varyantı da denenmiş olmalı.
- D3DMetal HDR'yi bildirmiyorsa: GPTK/CrossOver güncellemesi beklenir. MateBridge tarafında yapılacak bir şey yok.

## Prob

`probes/hdr-probe/` (çalıştırılmadı; talimatlar `probes/hdr-probe/README.md`):
- `hdr-probe inspect`: salt okuma. Bu raporun runtime, VT ve SCK satırları bununla üretildi.
- `hdr-probe vd [--tf N | --sweep] [--reference] [--p3] [--capture sdr|local|canonical|recording] [--hold S]`: **sanal ekran kurar**, kullanıcı onayı gerekir.
  - Ekran vendor 0x4D42 / product 0x0226 ile kurulur ve MateBridge'in ekranıyla çakışmaz.
  - Raporladığı alanlar: EDR değerleri, renk alanı, mod listesi, yakalanan karenin biçimi, etiketleri ve parlaklığı (nit).
- `hdr-probe encode [--path fast|llrc] [--transfer pq|hlg] [--fps] [--out clip.mp4]`: Main10 HDR kodlama süresini ölçer ve Android probu için klip üretir. **Akış kapalıyken** çalıştırılmalı.
- `android/`: klibi `SurfaceView`'da oynatır, yanında bir SDR beyaz yaması gösterir. Decoder adını, Main10HDR10 bildirimini ve çıkış biçimini `MBHDR` etiketiyle günlüğe yazar. Ölçüm sırasında `dumpsys SurfaceFlinger` okunur.

## Kaynaklar

- Apple, Sidecar Reference Mode EDR: https://developer.apple.com/videos/play/tech-talks/110337/
- Apple, EDR (WWDC21 10161): https://developer.apple.com/videos/play/wwdc2021/10161/
- Apple, SCK HDR (WWDC24 10088): https://developer.apple.com/videos/play/wwdc2024/10088/
- Apple forum, D3DMetal HDR color space (FB22330617): https://developer.apple.com/forums/thread/820469
- Apple forum, SCK HDR kırpma: https://developer.apple.com/forums/thread/815971
- Vibepollo PR #539 (macOS HDR virtual display): https://github.com/Nonary/Vibepollo/pull/539
- BetterDisplay v4.3.3 / SSS: https://github.com/waydabber/BetterDisplay/releases/tag/v4.3.3, https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/
- Sunshine PR #5817 (macOS SCK+VT, SDR/HDR): https://github.com/LizardByte/Sunshine/pull/5817; #5814 (LLRC tavanı): https://github.com/LizardByte/Sunshine/issues/5814
- Moonlight-android decoder: https://github.com/moonlight-stream/moonlight-android/blob/master/app/src/main/java/com/limelight/binding/video/MediaCodecDecoderRenderer.java
- AOSP HDR / mixed SDR-HDR: https://source.android.com/docs/core/display/hdr, https://source.android.com/docs/core/display/mixed-sdr-hdr
- moonlight-harmony (HarmonyOS NEXT): https://github.com/AlkaidLab/moonlight-harmony
- Flutter #179800 (HarmonyOS 4 decoder): https://github.com/flutter/flutter/issues/179800
- GSMArena MatePad Pro 12.2 (2025): https://www.gsmarena.com/huawei_matepad_pro_12_2_2025-review-2865.php
- Repo: T-047 (encode tezgâhı), T-053 (hızlı profil), T-113/T-188 (renk etiketleri, SDR doğrulaması), karar 0020/0026/0029/0030.
