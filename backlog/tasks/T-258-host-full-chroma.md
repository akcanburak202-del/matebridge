---
id: T-258
title: Host — packed full chroma (decision 0034): codecs, Metal AVC444v2 packer, second VT session, pairing, fallback
status: review
phase: 6
owner: mac-host-dev
depends_on: [T-257, T-253]
decisions: [0034, 0033, 0032]
files:
  - host-mac/Sources/MateBridgeCore/
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/
  - host-mac/Tests/
  - docs/LOGGING.md
  - docs/KNOBS.md
  - backlog/tasks/T-258-host-full-chroma.md
---

## Amaç

Karar 0034'ün host tarafı. Protokol ve fixture'lar `task/T-257-full-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-258-host-full-chroma task/T-257-full-chroma-protocol`). Protokolü değiştirme; uyuşmazlık görürsen Open questions'a yaz.

## Bağlam

- **Codec (Swift):** `STREAM_CONFIG.reserved` → `chroma_layout`, `VIDEO_FRAME.reserved` → `view`, `KEYFRAME_REQUEST` isteğe bağlı `view` (yoksa = iki akış; bilinmeyen = iki akış), `STREAM_PREFS.chroma` `2`. Bütün fixture testleri (yeni beş dahil) geçmeli.
- **Politika:** `chroma = 2` yalnız PROTOCOL §0x05 "Tam renk" koşullarında uygulanır (fps 60, doğal ekran, ölçek 1000, SDR); değilse `1` gibi (keskin). `MATEBRIDGE_CHROMA` önceliği korunur (yeni geliştirici değeri `packed444`). HDR kuralı (0032) aynen.
- **Paketleyici:** T-255 probunun Metal çekirdeği (`probes/yuv444-probe`, birleşik tek geçiş, `pick` ana renk seçimi) ürün koduna taşınır; `ChromaConverter` kalıbı (IOSurface havuzu, doku önbelleği). Çıktı iki `420f` tampon; T-113 etiketleri (oturum etiketleri, `retagForSession`) ikisine de: T-255 M4 bit-tamlık koşulu.
- **İki VT oturumu:** mevcut `HEVCEncoder` ana; ikinci örnek yardımcı (aynı hızlı profil, ayrı `AverageBitRate`/`DataRateLimits` = ana hedefin %50'si). Ana yardımcıyı beklemez; aynı yakalama için ana önce gönderilir; yardımcı `capture_time_us` = ananınki; `frame_seq` akış başına. Yardımcı kuyrukta en çok 2 kare, soket tıkanınca önce yardımcı atılır (PROTOCOL §5).
- **Anahtar kareler:** STARTUP/DECODE_ERROR/bilinmeyen `view` → iki akış (yardımcınınki bir kare kaydırılabilir); `view = 1` → yalnız yardımcı (+ onun CODEC_CONFIG'i). T-122 birleştirme her akışta ayrı. Periyodik IDR ikisinde.
- **T-253 netleştirme:** trenler iki akışta da çalışmalı (aynı yeniden gönderim yolu iki oturuma); bayt tavanı toplam. Codex'in T-253'te bulduğu sıralama kuralları (gerçek kare önceliği, bekleyen IDR) iki akış için de geçerli.
- **Geri düşüş:** yardımcı kodlama sürekli yetişemezse (pencere başına yardımcı kaybı > %5, birkaç pencere) ya da VT hatası → yeni `config_id` ile `chroma_layout = 0` (ana tek akış, normal 4:2:0 — keskin değil), `ev=chroma_fallback reason=`. Tercih korunur; sonraki ekran kipi değişiminde yeniden denenir.
- **Log:** `ev=chroma_config` (`layout=packed444`), `ev=chroma_stats` (paketleyici GPU ms, yardımcı enc ms, yardımcı/ana bayt oranı, yardımcı kaybı), `ev=chroma_fallback`. `docs/LOGGING.md`, `docs/KNOBS.md`.
- Mac'te pencere açma, uygulamayı çalıştırma; sanal ekran kurma. Komut satırı VT/Metal testleri serbest. Cihaz testi orkestratörde.

- **Oturum onayı (Codex T-257):** `HELLO.capabilities` bit11 `FULL_CHROMA`. Host: yardımcı akış yalnız bit11 + bu oturumda gelen son `STREAM_PREFS.chroma = 2` ile; hatırlanan tercih ya da `MATEBRIDGE_CHROMA=packed444` bunu aşamaz. Ana akış §5 sınırlı kuyruk kurallarına tabi; tıkanmada önce yardımcı atılır.

## Kabul kriterleri

- [ ] Fixture testleri (eski + yeni) geçer; `./scripts/check.sh` geçer.
- [ ] Birim testleri: politika (koşullar, env önceliği, HDR), anahtar kare yönlendirme (`view`), sıra (ana önce, yardımcı aynı `capture_time_us`), yardımcı kuyruk sınırı, geri düşüş kararı; paketleyici yazılım referansıyla bit-tam (T-255 testleri taşınabilir).
- [ ] Handoff: cihazda doğrulama adımları (2800 @60 Günlük, `ev=chroma_stats`, motor doluluğu, Wi-Fi bayt oranı, geri düşüş tetikleme yolu).

## Plan

Dal: `task/T-258-host-full-chroma` (T-257 üzerine). Protokole dokunulmaz.

1. **Codec (Core):** `StreamConfig.chromaLayout` (eski reserved), `VideoFrame.view`, `Message.keyframeRequest(reason, view:)` (isteğe bağlı ikinci bayt; yoksa `nil` = iki akış), `Capabilities.fullChroma` (bit11), `ChromaPreference.full` (2). Fixture testleri yeni beş dosyayı kapsar.
2. **Politika (Core, saf):** `VideoSettings` — `clientFullChroma` (HELLO bit11), `fullChromaGranted` (bit11 + bu oturumda gelen `chroma = 2` + fps 60 + doğal ekran + ölçek 1000 + SDR + HEVC + çalışma zamanı geri düşüşü yok), `packedChroma` (granted + env), `streamConfig.chromaLayout`. `applying(..., fullChroma: FullChromaSession)`: hatırlanan tercih (`prefsFromThisSession = false`) 1 gibi uygulanır; geri düşüşte `.normal`. `ChromaMode.packed444`, `ChromaPolicy` (env önceliği; `packed444` onay yoksa keskin yola düşer), `ChromaConfigLog` (`layout=packed444`).
3. **Paketleyici:** `AVC444v2` CPU referansı + Metal çekirdeği kaynağı (`PackedChromaKernel`, T-255 `pack_v2` birleşik tek geçiş, `pick`) Core'da; `PackedChromaPacker` (Host/Video, `ChromaConverter` kalıbı: IOSurface havuzu, doku önbelleği, T-113 etiketleri iki çıktıya). Testler: CPU referansı kendi içinde gidiş-dönüş, GPU çıktısı CPU ile bit-tam (Metal yoksa atlanır).
4. **İkinci VT oturumu:** `PackedAuxEncoder` (Host/Video): aynı hızlı profil, `AverageBitRate`/`DataRateLimits` = ana hedefin %50'si, en çok 2 uçuşta kare (doluysa yardımcı atılır ve yardımcı IDR beklenir), kendi CODEC_CONFIG'i (`view = 1`). `HEVCEncoder` paketleyiciyi owner kuyruğunda çalıştırır (`send`): ana tampon ana oturuma, yardımcı tampon `PackedAuxEncoder`'a aynı `capture_time_us` ve PTS ile. Yardımcı IDR bayrağı ayrı (`requestKeyframe(view:)`); refine kareleri yardımcı IDR'ı yemez, bekleyen yardımcı IDR refine trenini bitirir; refine bayt hesabı toplam (ana + yardımcı tahmini).
5. **Sıra ve sınır (Core, saf):** `PackedSendArbiter`: önce ana; yardımcı yalnız gönderilmiş bir ana karenin `capture_time_us`'u ile gider (ana henüz gelmediyse bekler, ana atılmışsa yardımcı atılır ve yardımcı IDR istenir). `VideoFrameQueue`'ya `tryPop/peek/breakChain/observer` eklenir; yardımcı kuyruk kapasitesi 2. `VideoSender` yardımcı kuyruğu alır (`frame_seq` akış başına, soket tıkanınca zaten yalnız ana önce çekilir, yardımcı bekler/atılır). Yardımcı IDR/CODEC_CONFIG yeniden eşzamanlama (`view` 1 ve 2) VideoPipeline'da.
6. **Geri düşüş (Core, saf):** `PackedChromaMonitor`: pencere (1 s) başına yardımcı kaybı > %5, 3 ardışık pencere, ya da VT/Metal/oturum hatası → `chroma_fallback reason=`. `StreamCoordinator`: yeni `config_id`, `chroma_layout = 0` (normal 4:2:0), tercih saklı kalır; sonraki ekran kipi değişiminde (`sameStreamMode`) bayrak silinir, yeniden denenir.
7. **Log/belge:** `ev=chroma_config layout=packed444`, `ev=chroma_stats` (paketleyici GPU ms, yardımcı enc ms, yardımcı/ana bayt oranı, yardımcı kaybı), `ev=chroma_fallback`; `docs/LOGGING.md`, `docs/KNOBS.md`.
8. **Test:** Core birim testleri (politika, env/HDR/onay, `view` yönlendirme, sıra, kuyruk sınırı, geri düşüş kararı, paketleyici bit-tamlığı). `./scripts/check.sh`.

## Handoff

- **Commit:** 297abc6 (kod), 2aa5cd5 (plan). Dal `task/T-258-host-full-chroma`, T-257 üzerine. `check.sh`: host-mac build+test, probes, fixture/crypto kontrolleri OK; **tek FAIL `gradle (client-android)`**: Kotlin `FixtureTest` "fixtures without a test case" (yeni beş fixture için T-259 vakaları henüz yok); T-258 kapsamı dışı.
- **Dokunulan dosyalar:** Core: `Messages.swift` (StreamConfig.chromaLayout, VideoFrame.view, KeyframeView, Capabilities.fullChroma, ChromaPreference.full), `Message.swift` (`keyframeRequest(reason, view:)`), `Video/PackedChroma.swift` (AVC444v2 CPU referansı + Metal kaynağı), `Video/PackedChromaFlow.swift` (`PackedSendArbiter`, `PackedChromaMonitor`, istatistik/log), `Video/FullChromaPolicy.swift`, `VideoSettings.swift`, `StreamPrefsPolicy.swift` (`applying(fullChroma:)`, `FullChromaSession`, `sameStreamMode`), `StreamSettings.swift`, `ChromaMode.swift` (`packed444`, `fullChromaDenied`, `ChromaPolicy.resolve(packedChroma:)`, log `layout=`), `VideoFrameQueue.swift`/`BoundedFrameQueue.swift` (tryPop/peek/breakChain/aktivite), `VideoSender.swift` (iki akış), `KeyframeRequestCoalescer.swift` (`aux_only`), `EncodedVideoFrame.swift`. Host: `Video/PackedChromaPacker.swift`, `Video/PackedAuxEncoder.swift`, `HEVCEncoder.swift`, `VideoPipeline.swift`, `Session/StreamCoordinator.swift`. Testler: `FixtureTests` (yeni beş fixture), `PackedChromaTests` (düzen, GPU = CPU, arbiter, monitor, kuyruk, gönderici), `FullChromaPolicyTests`, `ChromaPrefsTests`. Belge: `docs/LOGGING.md`, `docs/KNOBS.md`.
- **Tasarım:** `VideoSettings.fullChromaGranted` = HELLO bit11 + bu oturumda gelen `chroma = 2` (hatırlanan tercih `1` gibi) + fps 60 + doğal ekran + ölçek 1000 + SDR + HEVC + çalışma zamanı geri düşüşü yok; `MATEBRIDGE_CHROMA` önceliği korunur (`packed444` onay olmadan keskin yola düşer, `reason=full_chroma_denied`). Metal paketleyici `HEVCEncoder.send` içinde (owner kuyruğu): ana tampon ana VT'ye, yardımcı tampon `PackedAuxEncoder`'a (aynı PTS ve `capture_time_us`, en çok 2 uçuşta, doluysa atılır ve yardımcı IDR beklenir). Gönderici (`PackedSendArbiter`): önce ana; yardımcı yalnız gönderilmiş ana karenin `capture_time_us`'u ile, ana atılmışsa yardımcı atılır + yardımcı IDR; `frame_seq` akış başına. KEYFRAME_REQUEST: `view` akışı seçer (yok/2/bilinmeyen = ikisi; 0 ana; 1 yardımcı), `reason` yalnız o akışın CODEC_CONFIG'inin yeniden gönderilmesini belirler (orkestratörün Codex T-257 turu 2 netleştirmesi). Geri düşüş: `PackedChromaMonitor` (3 ardışık 1 sn pencere, kayıp > %5, en az 20 kare) ya da VT/Metal hatası: yeni `config_id`, `chroma_layout = 0`, tercih saklı; sonraki ekran kipi değişiminde (`sameStreamMode`) yeniden denenir.
- **Varsayımlar:** (1) Yardımcı akışın bit hızı (`AverageBitRate`/`DataRateLimits`) ana hedefin %50'si, canlı bit hızı değişimini izler. (2) T-253 refine bayt tavanı toplam: yardımcı bayt, ana baytın yarısı olarak tahmin edilir. (3) Yardımcı IDR ana IDR ile aynı karede olmak zorunda değil; bayrak ayrı, refine kareleri yardımcı IDR'ı yemez ve bekleyen yardımcı IDR refine trenini bitirir. (4) Paketleyici GPU'su CPU referansından kayan nokta yuvarlama bağlarında en fazla 1 kod farkedebilir (test ±1 ve < %0,2 tolere eder; düzen bit-tam). (5) Chroma konumu iki çıkışta `TopLeft` (`pick`).
- **Gerçek donanımda doğrulanacak (orkestratör, cihaz oturumu):** 2800x1840 @60 Günlük + panelden "Tam renk": `ev=chroma_config layout=packed444 view=main|aux`, STREAM_CONFIG `chroma_layout=1`; `ev=chroma_stats` (paketleyici GPU ms ~0,5-1, `aux_enc_ms`, `aux_main_bytes` 0,3-0,9, `aux_lost` ~0); kodlama motoru doluluğu (~%67 beklenir); Wi-Fi'da toplam bit hızı (~1,3-1,5x) ve ana/yardımcı büyük karelerin çakışması; yardımcı IDR yolları (DECODE_ERROR view=1: yalnız yardımcı IDR + yardımcı CODEC_CONFIG); geri düşüşü tetikleme (başka bir VT uygulamasıyla kodlama motorunu doldur; `ev=chroma_fallback`, yeni `config_id`, `chroma_layout=0`; sonra fps/ölçek değiştirip yeniden denendiğini gör); eski istemci (bit11 yok) ya da hatırlanan tercihle başlayan oturumda yardımcı akışın hiç gitmediği; T-113 etiketlerinin yardımcıda bit-tamlığı (T-255 M4'ün ürün içi karşılığı: yardımcı çıkışı VT renk dönüşümüne girmemeli). **Çalıştırılmadı:** ana uygulama, sanal ekran, VT oturumları (yalnız `swift test`; Metal çekirdeği CPU ile karşılaştırıldı, VT yolu ve `HEVCEncoder`/`StreamCoordinator` entegrasyonu derlendi ama çalıştırılmadı).

### Codex --high turu (6 x P2), aynı dalda düzeltildi

1. `PackedAuxEncoder`: geri çağrıda başarısız (veya zincir kırıldıktan sonra gelen) kare `onLoss` ile `auxLost` sayılır (fallback kuralına girer), yardımcı IDR yeniden kurulur; kırık zincirin delta'ları bir keyframe'e kadar atılır (`awaitingKeyframe`).
2. `idleTick` bekleyen yardımcı IDR'ı da servis eder (200 ms aralıkla `resubmitLast`), böylece iki yuva doluyken durağan ekranda takılma olmaz.
3. Yardımcı akışa kendi T-122 birleştiricisi: `auxKeyframes` kapısı + ikinci `EncoderBox(view: .auxiliary)` (kuyruk taşması `hostDrop`), `KEYFRAME_REQUEST` yardımcı kısmı `request(...)` ile; yeni yardımcı IDR yalnız kuyrukta/uçuşta/yeni yazılmış yokken zorlanır. Yardımcı keyframe "yazıldı" sayımı kuyruğa konma anında (yardımcı için yazma izi yok).
4. Refine: ana ve yardımcı çıkışlar `refinePairs` ile eşlenir, train gerçek toplam baytı (ana + yardımcı) görür; iki akışın birlikte yakınsaması toplam üzerinden sınanır; yardımcı kayıp/hata = train hatası.
5. Yardımcı bit hızı `Backend.setBitrate` (sıralı owner kuyruğu) içinde ana ile birlikte uygulanır; doğrudan çağrı kaldırıldı.
6. `VideoSettings.fullChromaFellBack` + `ChromaPolicy.resolve(packedFellBack:)`: çalışma zamanı geri düşüşü `MATEBRIDGE_CHROMA=packed444` ile bile normal 4:2:0 (`reason=full_chroma_fallback`); onaysız istek yine keskin. Birim testi eklendi (`FullChromaPolicyTests`). 1-5 Host hedefinde (test hedefi yok), derlendi, cihazda doğrulanacak: yardımcı callback hatası enjekte etmek zor; `ev=chroma_stats aux_lost` ve `chroma_fallback` izlenmeli, `DECODE_ERROR view=1` durağan ekranda yardımcı IDR'ın gelmesi.

### Codex turu 2 (2 x P2)

1. Yardımcı kayıp sayımı artık `VideoFrameQueue.discardedCount` (taşma + bekleyen akıştan reddedilen delta'lar + `breakChain` ile temizlenenler) kullanır; ana kuyruğun `droppedCount` (cadence) sayacı değişmedi. Geri çağrı hataları zaten `auxLost`'ta. Test: `testDiscardedCountIncludesRefusedAndPurgedFrames`.
2. Refine hazır koşulu ana ve yardımcı kuyruğun ikisini birden ister; çift çözümü (devam kararı) yardımcı kare kuyruğa konduktan sonra verilir (`auxOutput` sonrası `refinePairResolved`), böylece refine yardımcı taşması ya da zincir kırığı üretmez. Host hedefi, derlendi; cihazda doğrulanacak.

### Codex turu 3 (2 x P2)

1. `PackedAuxEncoder`: `ProfileLevel`, `ColorPrimaries`, `TransferFunction` veya `YCbCrMatrix` reddedilirse oturum kurulmaz (`AuxSetupError`), `HEVCEncoder` `PackedSetupError(reason: "aux_setup")` fırlatır: `chroma_layout = 0`, `ev=chroma_fallback reason=aux_setup` (eski `aux_session_failed` adı kalktı; `docs/LOGGING.md`'deki ad `aux_setup` olarak okunmalı).
2. İlk refine çifti tahmini artık ana + yardımcı: `lastMotionAuxBytes` (son gerçek yardımcı kare, refine olmayan) eklenir; yoksa ana/2. Host hedefi, derlendi; cihazda doğrulanacak.

### Codex turu 4 (2 x P2)

1. Gerileme düzeltildi: refine hazırlığı `RefineReadiness.ready(mainReady:auxReady:packed:)` (Core, test edildi); yardımcı kuyruk yalnız `settings.packedChroma` iken sayılır, Normal/Sharp/geri düşüş sonrası T-253 eskisi gibi çalışır.
2. Taşıyıcının reddettiği yardımcı kare `counters.auxDropped`'a sayılır (geri düşüş kuralının kullandığı sayaç).

### Codex turu 5 (2 x P2)

1. Eşleme artık zaman damgasıyla değil gönderim kimliğiyle: `EncodedVideoFrame.pairID` (kodlayıcı her `send` için artan sayaç; ana kare `FrameTrace.pairID` ile taşır, yardımcı `PackedAuxEncoder.encode(pairID:)` ile). `PackedSendArbiter` `pairID` ile çalışır; tel üzerindeki `capture_time_us` aynen ana karenin değeri (istemci onunla eşler). Refine kareleri sentetik daha geç damga taşısa da gerçek yakalamanın yardımcısı atılmaz. Test: `testRefinementTimestampsDoNotMakeARealAuxFrameLookLost` ve mevcut arbiter/gönderici testleri pairID ile.
2. Refine "keyframe due" koruması iki akışın periyodik IDR son zamanına bakar (`lastAuxKeyframeUs`). Host hedefi, derlendi.

## Open questions

- Orkestratörün sonradan gönderdiği kart açıklaması (KEYFRAME_REQUEST `view`/`reason`) için protokol dalını birleştirme komutu izin sistemi tarafından reddedildi; açıklama mesajdaki metne göre uygulandı (PROTOCOL §0x23 ile uyumlu varsayıldı). Birleştirme gerekirse orkestratör yapmalı; protokol değişikliği yok.
- `client-android` Kotlin `FixtureTest` yeni beş fixture'ı henüz bilmiyor (T-259 kapsamı); `check.sh` bu dalda bu yüzden gradle adımında düşer.
- Sabitler (arbiter belleği 8, monitor eşikleri %5 / 3 pencere / 20 kare) cihaz verisiyle ayarlanabilir.

### Codex turu 6 (2 x P2)

1. Refine devam kararı: çift çözüldüğünde kuyruk hazır değilse (gönderici henüz boşaltmadı) paketli modda tren `queue_busy` ile bitmez; `StillRefinePolicy.noteOutput(deferQueueBusy:)` sonraki kareyi bekletir, 25 ms `refineTick` (`tick` çalışan trende) kuyruklar boşalınca devam ettirir; bekleme üst sınırı `queueDrainWaitUs` (500 ms) sonra `queue_busy`; bekleyen keyframe/`keyframe_due` ve yeni yakalama treni yine bitirir/iptal eder. Paketsiz mod eski davranış (hemen `queue_busy`). Testler: `StillRefineTests` (üç yeni).
2. Gönderici tarafı yardımcı eşleşme düşüşü: `BoundedFrameQueue.breakChain` artık kuyruktaki ilk keyframe'e kadar olan delta'ları temizler, o keyframe ve sonrası kalır, `awaitingKeyframe` yalnız keyframe yoksa kurulur (taşma yolundaki mantıkla aynı). `VideoSender(auxPairingDropped:)` (verilmişse) eşleşme düşüşünde `requestAuxKeyframe` yerine bunu çağırır; `VideoPipeline.auxPairingDropped()` yardımcı kutunun `hostDrop`/ertelenmiş kontrol mantığına (T-176) gider (`resubmitNow: true`): kuyrukta kalan, kodlayıcıda bekleyen ya da yeni yazılmış keyframe varken IDR zorlanmaz, yoksa zorlanır/ertelenir, sert üst sınır var. Taşıyıcı reddi (`requestAuxKeyframe`, koşulsuz zorla) değişmedi. Dokunulan: `BoundedFrameQueue`, `VideoSender`, `StillRefine`, `HEVCEncoder`, `VideoPipeline`, `StreamCoordinator`, testler (`PackedChromaTests`: breakChain testleri güncellendi + 2 yeni, gönderici yönlendirme testi). Cihazda doğrulanacak: durağan ekranda `ev=refine` trenlerinin `frames` sayısı (queue_busy ile 1 kareden bitmemeli); sıkışık Wi-Fi'da art arda eşleşme kayıplarında yardımcı IDR sayısı (`idr=` aux).
