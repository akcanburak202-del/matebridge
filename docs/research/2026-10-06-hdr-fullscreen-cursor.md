# HDR10'da imleç gizlenince tam ekran oyunun aşırı parlaması (2026-10-06)

Soru: Oyun modu + HDR10 akışta tam ekran bir oyun (Astris, TotK; oyun içi HDR çıkışı "Perceptual" ya da "Linear") fare durduktan 4–5 sn sonra aşırı parlıyor, açık tonlar patlıyor. Fare oynayınca hemen düzeliyor; tuş basmak düzeltmiyor. Pencere modunda sorun yok. Host yakalaması iki durumda da 60 fps `complete`, `NSScreen` EDR potansiyeli iki durumda da 5,0. 1×1 px, alfa 0,005, `.screenSaver` seviyeli tıklama geçiren pencere işe yaramadı. Cihaz bulguları: `docs/NOTES.md` "2026-10-06 ~20:00–20:20".

Yöntem: repo okuma (`ScreenCapture.swift`, `VirtualDisplay.swift`, `HEVCEncoder.swift`, karar 0032/0036), bu Mac'te salt okuma (ObjC runtime listesi, dyld shared cache dizgileri, SDK başlıkları; ekran kurulmadı, pencere açılmadı, host çalıştırılmadı, tablete dokunulmadı) ve web.

Kanıt etiketleri (2026-10-04 HDR raporuyla aynı):
- **[Mac]**: bu Mac'te okundu (macOS 27.0.1, Mac mini M6).
- **[Repo]**: bu depodaki kod ya da belge.
- **[Kaynak]**: birincil kaynak (Apple belgesi, SDK başlığı).
- **[İddia]**: üçüncü taraf beyanı, doğrulanmadı.
- **[Tahmin]**: çıkarım.

## Özet

- **Mekanizma büyük olasılıkla "doğrudan ekrana" (direct-to-display / detached) yolu.**
  - İmleç görünürken WindowServer oyun katmanını diğer içerikle birlikte **birleştirir** (composite) ve EDR ton eşlemesini ekranın boşluğuna (5,0) göre yapar.
  - İmleç gizlenince ekranda tek bir opak tam ekran katman kalır ve sistem onu **doğrudan** ekran yüzeyine verir. Bu yolda renk ve ton işlemi farklı, macOS 26/27'de de hatalı görünüyor.
  - Sanal ekranda donanım imleç düzlemi yok [Tahmin]. SCK `showsCursor=true` yazılım imlecini canlı tutar [İddia]. Bu yüzden görünen imleç birleştirmeyi zorlar, gizli imleç zorlamaz.
- **Neredeyse birebir eşleşen rapor var:** Framegen #19 (2026-09-24). MacBook Pro'nun **fiziksel** XDR ekranında, Chrome'da tam ekran HDR "fare birkaç saniye durunca düz ve aşırı parlak oluyor, fare oynayınca düzeliyor, pencerede sorun yok". Orada da %0,4 alfalı perde ve opak küçük blok işe **yaramamış**, yalnız 1×1 px `backdrop-filter` (birleştirmeyi zorlayan efekt) düzeltmiş. Bizim 1×1 alfa pencere sonucumuzla aynı desen.
- **İmleci gizleyen macOS değil, oyun/emülatör.** Astris Ryujinx tabanlı. Ryujinx'in "Hide Cursor" varsayılanı "On Idle" ve **5 sn** [Kaynak, Ryujinx yapılandırma belgesi]. Tuşun düzeltmemesi bununla tutarlı: sayaç yalnız fare hareketinde sıfırlanıyor.
- **Sanal ekran parlaklık meta verisi** (`CGVirtualDisplay*`) içinde maks. nit, boşluk ya da HDR modu alanı yok. Yalnız EOTF (`transferFunction`), primerler ve `isReference` var. Eksik meta veri "birleştirilince doğru, doğrudan yolda parlak" farkını tek başına açıklamaz [Tahmin].
- **Önerilen sıra:**
  1. Ucuz teşhis: Metal HUD'da Direct/Composited göstergesi ve host'ta saniyede bir `hdr_diag` satırı.
  2. Birleştirmeyi zorlayan host katmanı (behind-window blur, 2×2 px).
  3. SCK `hdrLocalDisplay` / renk alanı varyantı.
  4. Son çare imleci "görünür tutmak". Kanıtlanmış bir yol ama imleç oyunun üstünde görünür.
  - Kullanıcının hemen yapabileceği geçici çözüm: Astris'te "Hide Cursor: Never" (Ryujinx'ten kaldıysa) ya da pencere modu.

## 1. İmleç gizlenince macOS'ta ne değişiyor?

### 1a. Doğrudan ekrana (direct-to-display / "detached") yolu

- **[Kaynak]** Apple: "When a Metal drawable is direct-to-display, the hardware composites it directly to the display … To enable direct-to-display, your app needs to run in full-screen mode, displaying an opaque CAMetalLayer layer and RGB content, and run on a Mac with Apple silicon. There may be other edge case conditions …" Doğrulama aracı olarak Metal HUD ya da Instruments gösteriliyor. https://developer.apple.com/documentation/metal/managing-your-game-window-for-metal-in-macos
- **[Kaynak]** Metal HUD üst satırı "Direct" ya da "Composited" sunum yolunu ve Game Mode durumunu gösteriyor. "When you are composited, there may be some additional buffering … due to system UI elements or your own additional layers overlapping the screen." (Tech Talk 110339). https://developer.apple.com/videos/play/tech-talks/110339
- **[İddia]** Mozilla 1747999: macOS'ta video katmanı "detached mode"a geçince parlaklık ve renk değişiyor. Katmana ana ekranın renk alanını zorla yazmak değişimi kaldırmış ama renk doğruluğunu bozmuş. Apple'dan cevap gelmemiş, WONTFIX. Yani "detached yolda renk işlemi farklı" sorunu yıllardır biliniyor. https://bugzilla.mozilla.org/show_bug.cgi?id=1747999
- **[Mac]** CoreDisplay dizgileri bir "display pipe" ve ayrılma (detach) kararları içeriyor:
  - İşlemler: `Linearize`, `System Gamma`, `Regamma`, matris, LUT; ayrıca `RunGPUDisplayPipe` ve `Fallback GPU Display Pipe`.
  - Ret nedenleri: `CoreDisplay is not detached because of 2084 display precision`, `… GPU engine required`, `… pipe currently bypassed`.
  - İmleç durumu: `CursorVisState for display 0x%08x set to kCursorPendingGlass`.
  - CoreAnimation tarafında `_CARenderUpdateInvalidateDetachedLayers`, `_ValidateDetachedLayer`.
  - **[Tahmin]** Doğrudan yolda yüzey, WindowServer'ın birleştirme geçişi yerine CoreDisplay'in ayrı renk hattından geçiyor. PQ/EDR içerik orada farklı yorumlanabilir. Sanal ekranda donanım DCP'si olmadığı için bu hat GPU yedeğiyle çalışıyor olabilir.

### 1b. İmleç neden belirleyici? (yazılım imleci)

- **[Kaynak, SDK]** `CGCursorIsDrawnInFramebuffer()` (CGRemoteOperation.h): imleç bir kaplama düzleminde değil de kare belleğine çiziliyorsa true döner. Sonuç tüm ekranların birleşimidir. Kamuya açık bir işlev (eski ama çalışıyor) ve teşhis için kullanılabilir.
- **[İddia]** groundy.com (macOS 26.5.1): donanım imleci ayrı bir kaplama düzleminde, yazılım imleci WindowServer tarafından kareye birleştiriliyor. `showsCursor = true` olan bir SCK akışı "the software-cursor path has to stay live". https://groundy.com/articles/the-macbook-neo-cursor-lag-workaround-recording-one-pixel-every-10-seconds/
- **[Mac]** WindowServer dizgileri: `WSDisplayStreamUpdateSoftwareCursor`, `displayStream->softwareCursorRequested == false`, `hardwareCursorCapable`, `hardwareCursorActive`, `CGXRequestSoftwareCursor`. Yakalama akışı (display stream) yazılım imleci isteyebiliyor.
- **[Repo]** Oyun modunda video imleci açık (karar 0036 madde 4: "Oyun'da her zaman Görüntüde"), yani `cfg.showsCursor = true` (`ScreenCapture.swift`, `VideoCursorSwitch`).
- **[Tahmin]** Sanal ekranda imleç her durumda yazılım imleci (kare belleğinde). Görünür imleç kareye çizilmek zorunda olduğu için oyun yüzeyi "doğrudan" olamaz ve birleştirilir. İmleç gizlenince engel kalkar.
  - Bizim 1×1 pencere ve Framegen'in opak bloğu neden işe yaramadı? Sistem küçük üst katmanları doğrudan yüzeyin üstüne ayrı bir düzlem ya da kopya olarak koyabiliyor olabilir. Bu doğrulanmadı.
  - `backdrop-filter`/blur ise alttaki pikselleri okumak zorunda olduğundan gerçek birleştirmeyi zorluyor [Tahmin].

### 1c. EDR ton eşlemesi ve macOS 26'nın yeni modeli

- **[Kaynak, SDK, QuartzCore CALayer.h]** macOS 26'da `wantsExtendedDynamicRangeContent` eskidi. Yerine `preferredDynamicRange` (`standard` / `constrainedHigh` / `high`) ve `contentsHeadroom` geldi. `toneMapMode` (macOS 15) üç değer alıyor: `automatic`, `never`, `ifSupported`.
  - `constrainedHigh`: "brightness is modulated to optimize for co-existence with other composited content".
  - **[Tahmin, ikinci hipotez H3]** Görünür imleç "başka birleştirilmiş içerik" sayılıyorsa sistem HDR'yi kısıtlı modda tutar. İmleç gizlenince tam boşluk açılır. Fiziksel ekranda bu tasarım gereğidir. Bizde PQ akış mutlak nit taşıdığı için tablette "aşırı parlak" görünür. NSScreen **anlık** EDR değeri (`maximumExtendedDynamicRangeColorComponentValue`) iki durumda ayrı ayrı kaydedilmedi; yalnız potansiyel 5,0 biliniyor. Teşhis satırı bunu ayırır.
- **[Kaynak]** `CAEDRMetadata` ve sistem ton eşlemesi katman düzeyinde tanımlı. Apple belgeleri bunun birleştirilmiş ya da doğrudan yolda nerede uygulandığını söylemiyor. https://developer.apple.com/documentation/metal/using-system-tone-mapping-on-video-content
- **[Kaynak]** Referans ekranda (`maximumReferenceExtendedDynamicRangeColorComponentValue` ≠ 0) sistem ton eşlemesi yapılmaz, uygulama kırpar. https://developer.apple.com/documentation/metal/implementing-tone-mapping-on-reference-displays

### 1d. Game Mode

**[Kaynak]** HUD Game Mode'u ayrıca gösteriyor. Game Mode tam ekran oyun ön plandayken açılır ve imleçle değişmez. **[Tahmin]** Neden değil. HUD ile birlikte görülüp elenebilir.

### 1e. Hipotezler ve gözlemlerle uyumu

| Gözlem | H1: doğrudan yolda farklı renk/ton işlemi | H2: SCK yakalaması imleç çizerken farklı dönüşüm yapıyor | H3: macOS 26 boşluk politikası (imleç = başka içerik) |
|---|---|---|---|
| Yalnız tam ekran | ✔ (doğrudan yol yalnız tam ekranda) | ✘ (pencerede de imleç gizlenebilir) | ✔/? |
| 4–5 sn = Ryujinx "On Idle" | ✔ | ✔ | ✔ |
| Fare hareketi düzeltiyor, tuş düzeltmiyor | ✔ | ✔ | ✔ |
| 1×1 alfa pencere düzeltmedi | ✔ (Framegen'de de aynı) | ✔ | ? |
| Fiziksel XDR'de de var (Framegen) | ✔ | ✘ (orada SCK yok) | ✔ |
| Host kare hızı ve EDR potansiyeli aynı | ✔ | ✔ | ✔ (anlık değer ölçülmedi) |

En olası: **H1**, H3 ikinci. H2 Framegen'i açıklamadığı için zayıf, ama bizde ayrıca etkili olabilir. Aşağıdaki teşhis paketi üçünü ayırır.

## 2. Bizim yakalama ayarlarımız ve alternatifleri

- **[Repo]** `ScreenCapture.swift`, HDR10 dalı:
  - Ayarlar: `captureDynamicRange = .hdrCanonicalDisplay`, `pixelFormat = x420` (10-bit 4:2:0 video aralığı), `colorSpaceName = itur_2100_PQ`, `colorMatrix = ITU_R_2020`.
  - Bunlar `captureHDRRecordingPreservedSDRHDR10` preset'inin değerleri. Bu preset'in kendisi `.hdrCanonicalDisplay` mı kullanıyor, okunmadı.
  - Oyun modunda `showsCursor = true`.
  - Kodlayıcı girdi etiketlerini 2020/PQ'ya yeniden yazıyor ama yalnız ilk yeniden yazmayı günlüğe alıyor (`retagLogged`). Akış ortasında SCK etiketleri değişirse bu görünmez.
- **[Kaynak]** SCK `hdrLocalDisplay`: "HDR with attributes of the local display", yani yakalayan ekranın özellikleriyle. `hdrCanonicalDisplay`: "attributes of the canonical display", başka HDR cihazlarla paylaşım için.
  - WWDC24 10088: "local display … capturing and rendering HDR content on the same screen; canonical … optimized for sharing with other HDR devices."
  - https://developer.apple.com/documentation/screencapturekit/sccapturedynamicrange
  - https://developer.apple.com/videos/play/wwdc2024/10088/
- **[İddia]** Apple forum 815971 (macOS 26): `colorSpaceName` verilince SCK ton eşlenmiş değer veriyor (en çok 1,0). Renk alanı **verilmeyince** ham değerler geliyor (> 1,0). Renk alanı ayarı SCK içinde ayrı bir dönüşüm hattı seçiyor. https://developer.apple.com/forums/thread/815971
- **[İddia]** codevisor PR #186: SCK pencere yakalamasında SDR beyazı 202 nit, ekran yakalamasında 100 nit. Vibepollo #539: sanal HDR ekranda ~140 nit. SCK'nin "SDR beyaz" seçimi yola göre değişiyor.
  - **[Mac]** SkyLight'ta `kSLCaptureStreamSDRWhiteNitsPQ` ve `kSLContentStreamSDRWhiteNitsPQKey` var. SCK'nin PQ çıkışındaki SDR beyazını içeride bir anahtar belirliyor; kamuya açık bir ayar değil.
  - https://github.com/851-labs/codevisor/pull/186
  - https://github.com/Nonary/Vibepollo/pull/539
- **Başka bir preset ya da ayar farkı kapatır mı?** Bilinmiyor.
  - **[Tahmin]** H1 doğruysa sorun kaynağın kendisinde, yani SCK'ye gelen ekran yüzeyinde. Preset değiştirmek ancak `local` yolu ekranın boşluğuna göre yeniden ton eşliyorsa yardım eder.
  - Ucuz bir A/B olduğu için denenmeye değer (aday A).
  - `showsCursor`: H2 doğruysa belirleyici. H1'de dolaylı rol oynuyor (yazılım imlecini canlı tutuyor). Aday D bunu ayırır.

## 3. Sanal ekranın HDR meta verisi

- **[Mac]** Runtime listesi (bugün yeniden okundu):
  - `CGVirtualDisplayDescriptor`: `name`, `vendorID/productID/serialNum`, `sizeInMillimeters`, `maxPixelsWide/High`, `red/green/bluePrimary`, `whitePoint`, `queue`, `terminationHandler`, `displayInfo` + `setDisplayInfoValue:forKey:`.
  - `CGVirtualDisplaySettings`: `modes`, `hiDPI`, `rotation`, `isReference`, `refreshDeadline`.
  - `CGVirtualDisplayMode`: `width/height/refreshRate`, `transferFunction`.
  - **Maks. nit, ortalama nit, EDR boşluğu ya da "HDR modu" alanı yok.**
- **[Mac]** `applySettings:` tarafındaki sözlük anahtarları: `CDVirtualDisplayModeEOTF`, `CDVirtualDisplayIsReferenceKey`, `CDVirtualDisplayRefreshDeadlineKey`, `CDVirtualDisplayHiDPIMode`, `CDVirtualDisplayRotationMode`, `CDVirtualDisplayModeList/Width/Height/RefreshRate`.
  - WindowServer'da `WS::Displays::CAVirtualDisplay::set_color_modes`, `set_chromaticities`, `is_active_preset_reference` ve QuartzCore'da `kCAVirtualDisplayPixelFormat` / `kCAVirtualDisplayPixelFormatFollowsMode` var. Bunlar `CGVirtualDisplay` API'sinden erişilebilir değil.
  - Parlaklık bilgisi yalnız AirPlay/`FigVirtualDisplay` tarafında var (`kFigVirtualDisplaySinkOption_HDRInfo`, `kFigVirtualDisplaySinkDeviceInfoKey_HDRInfo`). O yol bizim API'miz değil.
- **[Repo]** Bizim ekranımız: yalnız `transferFunction=1`. Primer verilmiyor, `isReference` verilmiyor (`VirtualDisplay.swift`). Apple'ın `SidecarDisplayAgent`'ı `tf=1`'den önce `setIsReference:1` çağırıyor (2026-10-04 raporu).
- **Eksik meta veri farkı açıklar mı?** Kısmen, zayıf. [Tahmin]
  - Birleştirilmiş yolda WindowServer içeriği **ekranın boşluğuna** (5,0 × SDR beyazı ≈ 700 nit, Vibepollo'nun 140 nit ölçümüyle) ton eşliyor. Bu boşluk EOTF=1'den geliyor, nit meta verisinden değil.
  - Doğrudan yolda bu ton eşleme ya hiç yapılmıyor ya da başka bir referansla yapılıyor (H1). Doğru nit meta verisi olsa bile doğrudan yol onu kullanmıyorsa fark kalır.
  - `isReference=1`, referans ekran davranışını (ton eşleme yok, kırpma) iki yolda da aynı yapabilir. O zaman iki durum aynı görünür ama hangi parlaklıkta olacağı belirsiz. Aday E.
  - Primer verilmemesi (P3/2020) renk tonunu etkiler, parlaklık farkını açıklamaz.

## 4. Bilinen raporlar

| Kaynak | Ne | Bizimle ilgisi |
|---|---|---|
| Framegen #19 (2026-09-24, MBP M4 Pro XDR, Chrome; bir yorumcu M5'te de görmüş) | "once the video fills the viewport … and the mouse sits still for a few seconds, the picture switches … to a flat, uniformly brightened image … Moving the mouse fixes it … Windowed playback is always fine." Denenenler: %0,4 alfa perde **hayır**, opak blok 2–300 px **hayır**, drop-shadow **hayır**, `backdrop-filter` (1×1 px bile) **evet** | **Birebir aynı desen**, fiziksel ekranda. Kök neden macOS'un tam ekran tek katman yolu; düzeltme birleştirmeyi zorlamak. https://github.com/MONZikWasTaken/Framegen/issues/19 |
| Mozilla 1747999 | macOS "detached mode"a girince video parlaklığı/rengi değişiyor; Apple cevap vermemiş | Doğrudan yolun renk işleminin farklı olduğu eski bir örnek. https://bugzilla.mozilla.org/show_bug.cgi?id=1747999 |
| Zed blog | Aynı uygulama bir makinede Direct, diğerinde Composited çalışmış; Direct'te imleç hareketinde kare kaybı | Direct/Composited'in donanıma ve koşula göre değiştiği, HUD ile görüldüğü. https://zed.dev/blog/120fps |
| groundy.com (macOS 26.5.1) | `CGCursorIsDrawnInFramebuffer` 0→1 geçişi; SCK `showsCursor=true` yazılım imlecini canlı tutuyor | Teşhis işlevi ve SCK–imleç ilişkisi |
| Apple forum 815971 | `colorSpaceName` verilince SCK ton eşlenmiş değer veriyor | Aday A'nın gerekçesi |
| Vibepollo #539 (Sunshine çatalı, macOS 27 HDR sanal ekran) | SDR beyaz ~140 nit, tepe = boşluk × 140; tam ekran/imleç sorunu **anılmıyor** | Aynı yolu kullanan tek açık kaynak host; sorunu ya görmediler ya yazmadılar |
| Sunshine/Moonlight macOS, Parsec, BetterDisplay | İmleçle değişen HDR parlaklığı için rapor **bulunamadı**. Moonlight-qt #1079 (Sonoma'da HDR soluk/parlak) istemci tarafı, ilgisiz. BetterDisplay SSS: sanal HDR ekran + yakalama uygulaması HDR desteklemeli | Doğrudan karşılığı yok. **[Tahmin]** macOS'ta HDR sanal ekran + tam ekran oyun akışı çok yeni (macOS 27 API'si), kullanıcı sayısı az |
| Ryujinx yapılandırma belgesi | Hide Cursor: Never / OnIdle (varsayılan, 1–10 sn, varsayılan 5) / Always | 4–5 sn'yi açıklıyor; "Never" geçici çözüm, "Always" anında yeniden üretme aracı. https://mintlify.com/yakushabb/mirror-ryujinx/user-guide/configuration |

## 5. Adaylar (sıralı)

Genel kural: değişiklikler host tarafında. Özel API yalnız `VirtualDisplay` içinde. Her aday önce bir geliştirici anahtarıyla gelir, varsayılan davranış değişmez. Cihaz testi tek oturumda yapılır, paralel olmaz.

Tüm adaylar için ortak test (≤ 5 dk):
1. Oyun + HDR Açık, Astris tam ekran.
2. Fareyi bırak, 8 sn bekle; tablette parlak mı?
3. Fareyi oynat; normal mi?
4. 3 tekrar.
5. Astris'te "Hide Cursor: Always" seçilebiliyorsa sorun anında üretilir ve bekleme gerekmez.

### 0. Teşhis paketi (önce, düzeltme değil)

**0a. Metal HUD (kod yok, 2 dk).**
- Astris'i HUD açık başlat:
  - `MTL_HUD_ENABLED=1 /Applications/Astris.app/Contents/MacOS/<exe>`
  - ya da `defaults write <bundle-id> MetalForceHudEnabled -bool YES`; bundle id `osascript -e 'id of app "Astris"'` ile bulunur.
- HUD oyunun kendi penceresinde, yani tablette görünür. Mac'te ayrı pencere açılmaz.
- Beklenen (H1): imleç görünürken "Composited", gizlenince "Direct", parlama aynı anda.
- HUD hep "Composited" kalırsa H1 elenir; H2/H3'e bakılır.
- Risk: yok (HUD kapatılınca biter). MoltenVK de `CAMetalLayer` kullandığı için HUD çalışmalı [Tahmin].
- Kaynak: https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud

**0b. Host `ev=hdr_diag` satırı (küçük kart, mac-host-dev).**
- Ne: geliştirici anahtarı `MATEBRIDGE_HDR_DIAG=1` ile, yalnız HDR10 akışta, saniyede bir ve değişince bir satır:
  - `cursor_visible` (`CGCursorIsVisible()`), `cursor_in_fb` (`CGCursorIsDrawnInFramebuffer()`), ikisi de kamuya açık.
  - `edr_cur/edr_pot/edr_ref`: sanal ekranın `NSScreen` `maximumExtendedDynamicRangeColorComponentValue`, `…Potential…`, `maximumReferenceExtendedDynamicRangeColorComponentValue` değerleri. H3'ü ayırır.
  - SCK kare eki: `SCStreamFrameInfo.contentRect`, `.scaleFactor`, `.contentScale`, `dirtyRects` sayısı.
  - `CVBuffer` renk etiketleri: primaries, transfer, matrix, `CGColorSpace` var/yok. Ayrıca `kCVImageBufferContentLightLevelInfoKey` / `MasteringDisplayColorVolumeKey` var mı.
  - IOSurface: `kIOSurfaceContentHeadroom` (macOS 15+, SDK'da var) ve `kIOSurfaceColorSpace` özeti.
  - Etiket değişimi: yeniden yazmadan **önceki** etiketler. Bugünkü `retagLogged` yalnız ilkini yazıyor.
  - Piksel özeti: 10-bit Y düzleminden seyrek örnekleme (ör. her 16. satır ve sütun, ~20 bin örnek, < 0,2 ms [Tahmin]). Değerler: `y_p50`, `y_p99`, `y_max` kodu ve PQ ile nit karşılığı: `nit = PQ_EOTF((Y−64)/876)`. Luma tam parlaklık değildir ama iki durumu karşılaştırmaya yeter.
- Ne ayırır:
  - Etiketler ya da `ContentHeadroom` değişiyorsa SCK farklı bir yüzey ya da yol veriyor (H1/H2).
  - `edr_cur` değişiyorsa H3.
  - `y_p50`'nin sabit bir katla artması "referans beyaz farkı" demektir (ör. 140→203 nit ≈ ×1,45). Orta tonların düzleşip yükselmesi "gamma'lı değer doğrusal okunmuş" demektir (Framegen sahibinin tahmini). `y_max` kodu tepe sınırını gösterir: birleştirilmişte ~700 nit beklenir, doğrudanda 1000 / 10000 nit gibi bir değer çıkabilir.
- Test: ortak test, iki durumda 10'ar sn log.
- Risk: düşük. Yalnız anahtar açıkken çalışır. Piksel içeriği değil, istatistik loglanır (gizlilik sorunu yok).

**0c. Görünmez pencere gerçekten tam ekran Space'inde miydi?** (Aday B'nin önkoşulu)
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)` çıktısında kendi pencere numaramızın `kCGWindowIsOnscreen = true` olarak bulunması. Pencerede ayrıca `isOnActiveSpace` ve `occlusionState.contains(.visible)` kontrol edilir.
- Görsel doğrulama için ilk denemede 48×48 kırmızı yapılır, tablette oyunun üstünde görünüyor mu bakılır.
- **[Kaynak/Tahmin]** `LSUIElement`/accessory uygulamada `canJoinAllSpaces + fullScreenAuxiliary` ve yüksek seviye genelde tam ekran Space'inde görünür. Framegen sonucu düşünülürse pencere büyük olasılıkla görünüyordu ama birleştirmeyi zorlamadı.

### A. SCK `hdrLocalDisplay` ve renk alanı varyantı (ucuz kod, düşük risk)

- Ne: geliştirici anahtarı `MATEBRIDGE_HDR_CAPTURE=canonical|local|local_nocs`.
  - `local`: `captureDynamicRange = .hdrLocalDisplay`, gerisi aynı.
  - `local_nocs`: yalnız teşhis amaçlı `colorSpaceName` verilmez (forum 815971'e göre ham değer). Sonuç `ContentHeadroom` ve etiketleriyle loglanır; akış bozuk görünebilir, gösterim için değildir.
  - Değişiklik `ScreenCapture.swift`'te 3–4 satır.
- Test: anahtarla host'u yeniden başlat, ortak test, 0b satırıyla karşılaştır.
- Olasılık: düşük-orta. H2'de yüksek; H1'de ancak `local` yol ekran boşluğuna göre yeniden ton eşliyorsa işe yarar.
- Risk: düşük. `local` SDR beyazını ya da tepe değerini değiştirebilir; masaüstü griliği (NOTES 2026-10-05) yeniden ölçülmeli.

### B. Birleştirmeyi zorlayan host katmanı (en olası gerçek düzeltme)

- Ne: HDR10 akış açıkken host, sanal ekranın bir köşesine 2×2 px bir pencere koyar. Pencere `NSPanel`, `nonactivatingPanel`, `ignoresMouseEvents`, seviye `.screenSaver` ya da `CGShieldingWindowLevel()`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. İçinde `NSVisualEffectView`: `blendingMode = .behindWindow`, `state = .active`, `material` en sade olanı.
  - Gerekçe: Framegen'deki `backdrop-filter` düzeltmesinin WindowServer düzeyindeki karşılığı. Arkadaki pencerenin bulanıklaştırılması, alttaki oyun pikselinin okunmasını gerektirir. Bu yüzden oyun yüzeyi doğrudan yola gidemez [Tahmin].
  - Alfa 0,005 pencere düz bir katmandı; sistem onu doğrudan yüzeyin üstüne ayrı bir düzlem ya da kopya olarak koyabiliyor olabilir.
  - Yedek varyant: `CALayer.backgroundFilters` (CIGaussianBlur) ya da `compositingFilter`. Bunlar layer-backed pencerede WindowServer tarafında da backdrop gerektiriyor mu, doğrulanmadı.
- Test:
  1. 0c doğrulaması ile birlikte, ilk denemede 48×48 kırmızı arka planlı (pencerenin göründüğünü görmek için).
  2. Sonra 2×2 blur.
  3. Ortak test; 0a HUD "Composited" kalmalı.
- Olasılık: orta. Kanıtlanmış bir analog var, ama WindowServer'ın blur'u ayrı bir yol olarak ele alıp alamayacağı bilinmiyor.
- Risk ve maliyet:
  - Ürün davranışı olarak Mac'te pencere açmak karar ister (karar kaydı; "Mac'te GUI yok" kuralı ajanlar için, ürün özelliği ayrı bir konu).
  - Doğrudan yolun gecikme kazancı kaybolur. Bugün imleç görünürken zaten birleştirilmiş durumdayız, yani iyi durumdaki gecikme aynı kalır.
  - GPU'da her karede küçük bir birleştirme maliyeti var.
  - 2 px blur kenarda fark edilmez [Tahmin].
  - Pencere yalnız HDR10 akışta ve yalnız sanal ekranda açılır; akış bitince kapanır.

### C. İmleci "görünür" tutmak (kanıtlanmış ama görünür etkisi var)

- Ne: HDR10 akışta ve `CGCursorIsVisible() == false` iken host, mevcut konuma 0 px (işe yaramazsa ±1 px gidip dönen) bir `mouseMoved` CGEvent'i gönderir. Kural: hiçbir düğme basılı değilken ve son gerçek girdiden en az 3 sn sonra. Olay `InputController`'ın tek gönderim sırasından geçer.
  - Kullanıcının elle yaptığı 1 px CGEvent denemesi bu mekanizmayı **zaten doğruladı**. 0 px'in Ryujinx/Avalonia'nın sayacını sıfırlayıp sıfırlamadığı bilinmiyor.
- Varyant: imleci ekranın sağ alt köşesine taşımak (ok gövdesi ekran dışında kalır, imleç "görünür" ama neredeyse görünmez). Mutlak fare kullanan oyunlarda konumu değiştirdiği için önerilmez.
- Test: ortak test; parlama hiç olmamalı.
- Olasılık: yüksek (mekanizma görüldü).
- Yan etkiler:
  - İmleç oyunun üstünde sürekli görünür. Asıl kullanıcı maliyeti bu.
  - Sentetik olay kullanıcı etkinliği sayılabilir; Mac ekran uykusunu ve ekran koruyucuyu engeller [Tahmin]. Yalnız akış ve oyun ön plandayken açık olmalı.
  - Fareyle kamera çeviren oyunlarda ±1 px titreme yapar; göreli fare yakalayan oyunlarda (`CGAssociateMouseAndMouseCursorPosition(false)`) gereksizdir, çünkü imleç zaten gizlidir.
  - Girdi kuralları açısından basılı düğme bırakılmaz ve yeni bir basılı durum yaratılmaz. Yine de input-state incelemesi (Codex) gerekir.
- `CGDisplayShowCursor` / `NSCursor.setHiddenUntilMouseMoves(false)` işe **yaramaz**. Bunlar yalnız çağıran uygulamanın kendi gizleme sayacını etkiler; Astris'in gizlemesini geri alamaz [Tahmin: gizleme sayacı uygulama/bağlantı başına tutuluyor, doğrulanmadı]. Başka uygulamanın imlecini zorla göstermek için özel CGS çağrıları gerekir, `VirtualDisplay` kuralı dışında kalır; önerilmez.

### D. Oyun + HDR'de `showsCursor = false` (H2 ayırıcı)

- Ne: geliştirici anahtarı ile Oyun modunda da video imlecini kapatmak (yalnız test için; Oyun'da yerel imleç yok, imleç görüntüden kaybolur).
- Okuma:
  - Parlama aynı zamanlamayla sürüyorsa H1: imleç kare belleğinde, yakalamadan bağımsız.
  - Hep parlak oluyorsa: imleç yalnız yakalama akışı istediği için yazılım imleci olarak çiziliyordu. Bu durumda B ya da C şart.
  - Hiç olmuyorsa H2: düzeltme = HDR'de yakalamada imleç kapalı + tablette yerel imleç.
- 0b'nin `cursor_in_fb` değeriyle birlikte okunur.
- Risk: düşük (anahtar).

### E. `isReference = true` (Sidecar deseni; özel API, yalnız `VirtualDisplay`)

- Ne: `MATEBRIDGE_VD_REFERENCE=1` ile `CGVirtualDisplaySettings.setIsReference:YES`, `tf=1` ile birlikte (`SidecarDisplayAgent` sırası).
- Okuma: `edr_ref` (0b) sıfırdan farklı olmalı. Referans ekranda sistem ton eşlemesi yapılmadığından iki yol aynı davranabilir [Tahmin].
- Olasılık: düşük-orta; yan etkisi bilinmiyor (SDR beyazı, Ekranlar'daki ön ayar, HDR anahtarı).
- Test: ekran yeniden kurulur (karar 0020), sonra ortak test.
- Risk: orta. Hiç ölçülmedi; `hdr-probe vd --reference` probu yazılı ama çalıştırılmadı.

### F. Tam ekran oyunda pencere yakalama (büyük değişiklik, sonra)

- Ne: tam ekran HDR oyun algılanınca SCK filtresini `SCContentFilter(desktopIndependentWindow:)` ile o pencereye çevirmek.
- **[İddia]** codevisor'a göre pencere yakalaması farklı bir yol (SDR beyaz 202 nit). Pencere içeriğini WindowServer'ın pencere birleştirmesinden alıyorsa doğrudan yoldan etkilenmeyebilir [Tahmin].
- Maliyet yüksek: pencere değişimi, menü ve bildirimlerin akışa girmemesi, imleç, ölçek. Ancak B ve C başarısız olursa düşünülmeli.

### G. Önerilmeyenler

- Host'ta "doğrudan" durumu algılayıp GPU ile ters dönüşüm uygulamak: dönüşüm bilinmiyor, oyuna ve moda göre değişir; kırılgan.
- WindowServer `defaults` ile doğrudan yolu kapatmak: kamuya açık bir anahtar bulunamadı. Olsa bile sistem geneli ve root/yeniden oturum ister.

### Kullanıcı tarafı geçici çözümler

1. Astris → Ayarlar → "Hide Cursor: Never" (Ryujinx seçeneği korunmuşsa). İmleç görünür kalır, birleştirilmiş yol sürer.
2. Pencere modu (NOTES'taki geçici çözüm).
3. Astris SDR çıkışı.

Ayrıca Apple'a Feedback (Framegen'le aynı belirti, fiziksel ekranda) ve Astris'e not: `CAMetalLayer.toneMapMode` / `preferredDynamicRange` ayarı onlarda fark yaratabilir.

## Önerilen sıra ve kartlar

| Sıra | İş | Kim | Maliyet | Cihaz |
|---|---|---|---|---|
| 1 | 0a HUD + Astris "Hide Cursor" ayarına bakış | Kullanıcı (orkestratör yönlendirir) | 5 dk | 1 kısa oturum |
| 2 | 0b `hdr_diag` + A (`MATEBRIDGE_HDR_CAPTURE`) + D (`showsCursor` anahtarı) tek kartta, hepsi geliştirici anahtarı | mac-host-dev | ~0,5 gün | 1 oturum (~15 dk, 4 varyant) |
| 3 | Sonuca göre B (karar kaydı + kart) ya da E | Orkestratör + mac-host-dev | B ~0,5–1 gün | 1 oturum |
| 4 | B/E başarısızsa C (Codex input-state incelemesiyle) ya da F | mac-host-dev | C ~0,5 gün, F 2+ gün | 1 oturum |

## Kaynaklar

- Apple, Managing your game window for Metal in macOS (direct-to-display koşulları): https://developer.apple.com/documentation/metal/managing-your-game-window-for-metal-in-macos
- Apple Tech Talk 110339 (Metal HUD, Direct/Composited): https://developer.apple.com/videos/play/tech-talks/110339
- Apple, Customizing Metal Performance HUD: https://developer.apple.com/documentation/xcode/customizing-metal-performance-hud
- Apple, SCCaptureDynamicRange: https://developer.apple.com/documentation/screencapturekit/sccapturedynamicrange ; WWDC24 10088: https://developer.apple.com/videos/play/wwdc2024/10088/
- Apple, system tone mapping / reference displays: https://developer.apple.com/documentation/metal/using-system-tone-mapping-on-video-content , https://developer.apple.com/documentation/metal/implementing-tone-mapping-on-reference-displays
- SDK başlıkları (bu Mac): QuartzCore `CALayer.h` (`toneMapMode`, `preferredDynamicRange`, `contentsHeadroom`), IOSurface `IOSurfaceRef.h` (`kIOSurfaceContentHeadroom`), CoreGraphics `CGRemoteOperation.h` (`CGCursorIsVisible`, `CGCursorIsDrawnInFramebuffer`)
- Apple forum 815971 (SCK HDR, renk alanı ve ton eşleme): https://developer.apple.com/forums/thread/815971
- Framegen #19 (tam ekran HDR, imleç durunca parlama, backdrop-filter düzeltmesi): https://github.com/MONZikWasTaken/Framegen/issues/19
- Mozilla 1747999 (detached mode parlaklık değişimi): https://bugzilla.mozilla.org/show_bug.cgi?id=1747999
- Zed, 120 fps (Direct vs Composited): https://zed.dev/blog/120fps
- groundy.com, donanım/yazılım imleci ve SCK `showsCursor`: https://groundy.com/articles/the-macbook-neo-cursor-lag-workaround-recording-one-pixel-every-10-seconds/
- codevisor PR #186 (SCK HDR SDR beyazı pencere/ekran): https://github.com/851-labs/codevisor/pull/186
- Vibepollo PR #539 (macOS 27 HDR sanal ekran): https://github.com/Nonary/Vibepollo/pull/539
- Ryujinx yapılandırma (Hide Cursor): https://mintlify.com/yakushabb/mirror-ryujinx/user-guide/configuration
- BetterDisplay sanal ekran HDR SSS: https://betterdisplay.pro/guide/faq/scaling/virtual-screen-hdr/
- Repo: `host-mac/Sources/MateBridgeHost/Video/ScreenCapture.swift`, `VirtualDisplay.swift`, `Video/HEVCEncoder.swift`; karar 0020, 0032, 0036; `docs/research/2026-10-04-hdr-feasibility.md`; NOTES 2026-10-06 ~20:00.
