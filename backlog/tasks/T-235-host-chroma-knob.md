---
id: T-235
title: Host dev knob MATEBRIDGE_CHROMA=420|sharp_bilinear|sharp_nearest|444 — sharp-YUV (luma adjustment) 4:2:0 via a Metal pass, plus a native 4:4:4 probe value; colour test page
status: done
phase: 6
owner: mac-host-dev
depends_on: [T-233]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - host-mac/Package.swift
  - tools/chroma-test/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-235-host-chroma-knob.md
---

## Amaç

T-233 araştırmasının (docs/research/2026-10-05-yuv444.md §3b ve "Kart A") uygulaması. Kullanıcı 2026-10-05: "deneriz, hoş görünüyorsa kullanırız". Dock'taki kırmızı ikon gibi doygun renk kenarlarındaki basamaklanmayı (4:2:0 luma hatası) host tarafında, protokole ve istemciye dokunmadan azaltmak; ayrıca tablet çözücüsünün gerçek 4:4:4 akışına ne yaptığını bir kez görmek.

## Bağlam

- Geliştirici anahtarı `MATEBRIDGE_CHROMA` (decision 0026 sınıfı, env, host `knobs=` alanı). Varsayılan `420` = bugünkü yol bit-bit aynı (SCK `420f` → VT).
- `sharp_bilinear` / `sharp_nearest`: SCK `BGRA` → Metal compute kernel: 2×2 renk alt örnekleme + piksel başına luma ayarı (araştırmadaki ikili arama ya da libwebp sharpyuv benzeri yinelemeli yöntem; planda seç), çözücünün rengi çift doğrusal ya da en yakın komşu büyüttüğünü varsayan iki değişken → `420f` CVPixelBuffer (aynı 709/sRGB/709 etiketleri, T-113) → mevcut HEVCEncoder. Metal pass süresi ve yakalama→kodlama süresi loglanır (`ev=chroma_stats` 10 sn pencerede p50/p95).
- `444`: SCK `BGRA` + VT profil `"HEVC_Main444_AutoLevel"` yalnız hızlı yolda (LLRC açıksa reddet ve `420`'ye dön, logla). Her oturumda SPS `chroma_format_idc` ayrıştırılıp `ev=chroma_config requested= applied= chroma_format_idc=` yazılır (araştırma: VT LLRC'de sessizce 4:2:0'a düşebiliyor). İstemci değişmez; tabletin çözücüsü hata verebilir ya da bozuk görüntü gösterebilir. Bu değer yalnız bir kez denemek içindir.
- Dikkat: araştırma host'un akışa chroma location yazmadığını not etti (yarım piksel renk kayması olabilir). Planda değerlendir; sharp değerlerinde VUI `chroma_sample_loc` yazılabiliyorsa yaz (yalnız knob açıkken).
- GPU maliyeti: Oyun modunda da çalışır (deneme). Karar sonuçlara göre (kart B).
- Test sayfası: `tools/chroma-test/index.html` (tek dosya, çevrimdışı): kırmızı/mavi/yeşil/mor ikon benzeri yuvarlak kareler gri ve koyu zeminde, renkli yazı (12–16 px), 1 px renkli çizgiler, kırmızı-mavi ızgara. Kullanıcı Safari'de açar.
- Pencere açma, sanal ekran kurma, çalışan host'a dokunma. Metal ve VT kısa sentetik denemeler kabul (canlı akış kodlayıcıyı paylaşır).

## Kabul kriterleri

- [x] [XCTest] Knob ayrıştırma ve geri dönüş kararları (LLRC + 444 → 420) saf fonksiyon olarak test edilir; luma ayarının CPU referans uygulaması küçük sentetik bloklarda (kırmızı/gri kenar) bilinen PSNR iyileşmesini verir; Metal kernel çıktısı CPU referansıyla ±1 kod değerinde eşleşir (Metal test ortamında yoksa probe/CLI ile, Handoff'ta).
- [x] Varsayılan yolda yakalama biçimi ve kodlayıcı ayarları değişmez.
- [x] `ev=chroma_config`, `ev=chroma_stats` docs/LOGGING.md'de; knob docs/KNOBS.md'de.
- [x] `./scripts/check.sh` geçer.
- [ ] [device, orkestratör + kullanıcı] Dört değer sırayla: test sayfası ve Dock (kullanıcı gözle; gerekirse telefon fotoğrafı), `444` için istemci `ev=decoder_output_format`/hata, gecikme farkı. Sonuç NOTES'a; olumluysa kart B (karar).

## Plan

1. **Core (saf, test edilir)** `MateBridgeCore/Video/ChromaMode.swift`:
   - `ChromaMode` (`420`, `sharp_bilinear`, `sharp_nearest`, `444`) ve `ChromaKnob.parse` (`MATEBRIDGE_CHROMA`; yok/boş = `420`, `set=false`; geçersiz = `420`, `invalid`).
   - `ChromaPolicy.resolve(knob, codec, profile)` → `requested/applied/reason`: `444` yalnız HEVC + `fast`; LLRC'de `reason=llrc`, H.264'te `reason=codec` ile `420`. Sonradan düşüşler aynı türle: `profile_rejected` (VT Main444'ü reddetti), `metal_unavailable` (kernel kurulamadı).
   - Yakalama biçimi kararı: `420` → `420f` (bugünkü), `sharp_*`/`444` → `BGRA`.
   - `ChromaStatsWindow` (10 sn, sınırlı örnek): dönüşüm duvar süresi, GPU süresi, yakalama (SCK geri çağrısı) → kodlayıcı çıkışı; `ev=chroma_stats` alanları p50/p95. `ev=chroma_config` alanları.
   - `HEVCSPS.chromaFormatIdc` / `generalProfileIdc` ve VUI `chroma_loc_info` okuma (mevcut BitReader).
2. **Core CPU referansı** `SharpYUV.swift`: BGRA → `420f` tam aralık BT.709 (2×2 kutu ortalaması Cb/Cr; luma ayarı = her piksel için 8 adımlı tamsayı ikili arama, çözücünün renk büyütmesi `bilinear` (ortalanmış konum) ya da `nearest` varsayımıyla, hedef sRGB EOTF sonrası doğrusal BT.709 parlaklığı); düz 4:2:0 ve yeniden kurma + açıklık PSNR yardımcıları. Metal kernel kaynağı da Core'da dize olarak (`SharpYUVKernel.metalSource`), böylece XCTest kernel'i düz MTLTexture'larla çalıştırıp CPU referansıyla ±1 karşılaştırır (Metal aygıtı yoksa test atlanır).
3. **Host** `Video/ChromaConverter.swift`: Metal (çalışma zamanında derlenen kaynak), `CVMetalTextureCache`, sınırlı `CVPixelBufferPool` (420f, IOSurface, eşik aşılırsa kare BGRA olarak VT'ye gider ve `conv_fail` sayılır). İki geçiş (renk bloğu, luma) tek komut tamponunda, eşzamanlı bekleme. Çıkışa oturum renk etiketleri + `ChromaLocation=Center` eklenir (VUI'ye yazılırsa `chroma_loc=1` loglanır; sentetik VT denemesiyle kontrol).
4. **HEVCEncoder**: knob'u çözer; `444` için ProfileLevel `"HEVC_Main444_AutoLevel"` (red → Main + `profile_rejected`); `sharp_*` için dönüştürücüyü sahiplenir ve dönüşümü sahip kuyruğunda (`send`, yalnız gerçekten gönderilen karelerde, `submittedUs`'tan önce) yapar; BGRA dışı girdi olduğu gibi geçer (benchler). İlk/değişen parametre setlerinde `ev=chroma_config`. Knob yoksa hiçbir yeni satır ve ayar yok (bit bit aynı yol).
5. **VideoPipeline/ScreenCapture**: yakalama biçimi kodlayıcının uyguladığı moddan; `420f` dalı satır satır aynı kalır. **StreamCoordinator**: saniyelik `reportCadence` içinde 10 sn dolunca `video ev=chroma_stats`.
6. `StreamProfileLog.knobAllowList`'e `MATEBRIDGE_CHROMA`; `EncoderKnobs.logFields` yalnız ayarlıyken `chroma=`.
7. `tools/chroma-test/index.html` (tek dosya, çevrimdışı). `docs/KNOBS.md` satır 44, `docs/LOGGING.md` bölüm.
8. XCTest: parse/resolve/fallback, yakalama biçimi, CPU referansı kırmızı/gri kenarda açıklık PSNR artışı (bilinear ve nearest), Metal ±1, SPS chroma ayrıştırma (sentetik SPS), stats penceresi. `./scripts/check.sh`.

## Handoff

- **Commit:** plan `714b760`; uygulama `b7bc247`; bu Handoff bir sonraki commit. Dal `task/T-235-chroma-knob`.
- **Dokunulan dosyalar:**
  - Yeni: `host-mac/Sources/MateBridgeCore/Video/ChromaMode.swift` (knob, `ChromaPolicy`, `ChromaConfigLog`, `ChromaStatsWindow`, `ChromaBitstreamInfo`, H.264 chroma), `SharpYUV.swift` (CPU referansı), `SharpYUVKernel.swift` (Metal kaynağı); `host-mac/Sources/MateBridgeHost/Video/ChromaConverter.swift`; testler `ChromaKnobTests.swift`, `SharpYUVTests.swift`; `tools/chroma-test/index.html`.
  - Değişen: `HEVCSPS.swift` (`summary`: profile/chroma/VUI `chroma_loc`; `vuiColor` aynı davranış), `EncoderKnobs.swift` (`chroma`, allow list, `StreamProfileLog.value` public), `HEVCEncoder.swift`, `ScreenCapture.swift`, `VideoPipeline.swift`, `SharpnessBench.swift` (knob BGRA istiyorsa BGRA kare besler, sonda `chroma_stats`), `StreamCoordinator.swift` (10 sn'de `video ev=chroma_stats`), `docs/KNOBS.md` (#44), `docs/LOGGING.md` (yeni bölüm; `knobs=` sıra listesine `VD_TRANSFER, CHROMA` eklendi, T-232'den eksikti). `Package.swift` değişmedi.
- **Tasarım özeti:**
  - Knob yok/boş → `420`, hiçbir yeni ayar, satır ya da kilit yok (ProfileLevel aynı çağrı, yakalama `420f`, `ScreenCapture` satırları aynı; yalnız `pixelFormat` parametresi varsayılanla geçiyor). `chroma_config`/`chroma_stats` yalnız knob tanımlıyken (taban için `MATEBRIDGE_CHROMA=420`).
  - `sharp_*`: Metal geçişi kodlayıcının sahip kuyruğunda, yalnız gerçekten gönderilen karelerde (`send`, `submittedUs`'tan önce; pacer'ın attığı karelere GPU harcanmaz), eşzamanlı bekleme. Havuz eşiği 8; geçiş başarısızsa kare BGRA olarak VT'ye gider (`conv_fail`, ilk hata `W ev=chroma_convert_failed`). Çıkışta oturum renk etiketleri + `ChromaLocation=Center`.
  - Algoritma: 2×2 kutu ortalaması Cb/Cr; luma = çözücü modeliyle (renk büyütme varsayımı, BT.709, sRGB EOTF tablo + doğrusal ara değer) kaynağın doğrusal parlaklığına en yakın Y kodu. Düz pikseller (katkı veren tüm renk örnekleri = pikselin kendi rengi) düz Y'yi korur. GPU: sekant tahmini + dörtnala + ikiye bölme (monotonluk sayesinde CPU'nun düz ikiye bölmesiyle aynı sonuç).
  - `444`: HEVC + `fast` profilde `HEVC_Main444_AutoLevel`; red → Main + `profile_rejected`; LLRC → `reason=llrc`, H.264 → `reason=codec` (yakalama `420f`).
- **Ölçümler (Mac mini M6, sentetik, pencere/sanal ekran/yakalama yok):**
  - XCTest: Metal kernel CPU referansıyla **bit bit aynı** (max |dY| = |dC| = 0; 67×45 tek boyut, gri/koyu zemin, rastgele yama, beyaz üstünde saf mavi, siyah üstünde sarı; düz, bilinear, nearest).
  - Açıklık (L*) PSNR, CPU referansı: kırmızı/gri 29,5 → 63,0 dB (bilinear), 29,7 → 66,4 (nearest); macenta/koyu 30,2 → 57,6 / 29,0 → 46,5. Yanlış varsayım (bilinear ayarlı, nearest gösterim) 29,7 → 39,3 dB (araştırmadaki ~+9 dB ile uyumlu).
  - Sentetik VT (scratch, 640×480, 3 kare): `ChromaLocation=Center` etiketli 420f girdi VUI'ye `chroma_loc_info` (tip 1) yazıyor; `_Left`/etiketsiz yazmıyor. Main444 + BGRA: SPS `profile_idc=4 chroma_format_idc=3`, `vui_full_range=0` (VT video aralığına çeviriyor).
  - `--sharpness-bench` (2800×1840, gerçek `HEVCEncoder` + Mac'te çözme; canlı akış kodlayıcıyı paylaşıyor olabilir, gürültülü): 120 fps, 240 kare, yoğun renkli metin sayfası: `420` `cap_enc` p50 6,6 ms; `sharp_bilinear` dönüşüm duvar p50/p95 2,6/3,3 ms (GPU 2,0/2,8), `cap_enc` 8,7/13,0; `sharp_nearest` 2,2/2,3 (GPU 1,7/1,7), `cap_enc` 8,3/8,6. `444`: `profile=main444`, `chroma_format_idc=3`, `cap_enc` 7,6/11,5. LLRC+444 ve H.264+444 → `W … applied=420 reason=llrc|codec`; geçersiz değer → `reason=invalid_value`.
  - Yalnız kernel (scratch, 120 fps aralıklı, GPU düşük saatte): masaüstü benzeri içerik ~1,5 ms, düz ekran ~0,9 ms, her yeri renkli nokta (en kötü) ~4,9 ms; arka arkaya (yüksek saat) en kötü ~1,8 ms. Gri/siyah metin düz sayılır (renk nötr), maliyeti renkli içerik belirliyor. Araştırmanın "<1 ms" tahmini yalnız düz ekranda tutuyor.
- **Varsayımlar:**
  - Tablet çözücüsü/DSS renk büyütmesi ya ortalanmış çift doğrusal ya da en yakın komşu; VUI `chroma_loc=1`'e uyup uymadığı bilinmiyor (iki değişkenin A/B nedeni bu).
  - Ekran EOTF'u sRGB parçalı eğri (STREAM_CONFIG transfer 13); gamma 2.2 ise kazanç biraz düşer.
  - SCK `BGRA` + `colorSpaceName = sRGB` değerleri bugünkü `420f` yolundaki sRGB kodlamasıyla aynı; `colorMatrix` BGRA'da yok sayılıyor (değiştirilmedi).
  - `444`'te VUI video aralığında; STREAM_CONFIG tam aralık diyor. Bu değer yalnız "çözücü kabul ediyor mu" denemesi; görüntü açılırsa siyah/beyaz seviyeleri yanlış olabilir.
- **Test edilmeyenler (cihaz / orkestratör):**
  - Gerçek SCK `BGRA` yakalaması (canlı host'a ve sanal ekrana dokunulmadı): `CVMetalTextureCache`'in SCK IOSurface'larıyla çalışması, satır hizası, BGRA kuyruk belleği (5 × ~20 MB).
  - Tablette görüntü: dört değer, test sayfası + Dock (telefon fotoğrafı), `sharp_*` kazancı ve renk saçağı; `444`'te istemci `ev=decoder_output_format` / `decode_error` / yeşil-bozuk görüntü.
  - Gerçek akışta gecikme farkı (`ev=chroma_stats cap_enc_ms`, `ev=latency`) ve Oyun modunda GPU yükü (oyun GPU'yu doldururken geçiş uzayabilir).
  - Metal derleme ilk pipeline başlangıcında ~100–200 ms (süreç başına bir kez); ölçülmedi.
- **Orkestratör için cihaz sırası önerisi:** `MATEBRIDGE_CHROMA=420` (taban) → `sharp_bilinear` → `sharp_nearest` → `444`; her birinde `ev=chroma_config` (özellikle `444`: `applied=444 chroma_format_idc=3`) ve 10 sn'lik `ev=chroma_stats`. `tools/chroma-test/index.html` Safari'de.
- **Açık sorular:**
  - Dönüşüm sahip kuyruğunu ~2–3 ms (en kötü ~5 ms) bekletiyor; 120 fps'te verim yetiyor (kuyruk başına bir dönüşüm, VT iki kare paralel), gecikme ekliyor. Kart B'de benimsenirse optimizasyon (blok başına iş parçacığı, renk farkı küçükse atlama eşiği) ayrı iş olabilir.
  - `444`'ün tam aralık olması gerekirse (çözücü kabul ederse) host'ta BGRA → `444f` dönüşümü ya da VT ayarı ayrıca araştırılmalı (kart C).
