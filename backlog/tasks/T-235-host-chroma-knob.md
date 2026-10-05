---
id: T-235
title: Host dev knob MATEBRIDGE_CHROMA=420|sharp_bilinear|sharp_nearest|444 — sharp-YUV (luma adjustment) 4:2:0 via a Metal pass, plus a native 4:4:4 probe value; colour test page
status: in-progress
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

- [ ] [XCTest] Knob ayrıştırma ve geri dönüş kararları (LLRC + 444 → 420) saf fonksiyon olarak test edilir; luma ayarının CPU referans uygulaması küçük sentetik bloklarda (kırmızı/gri kenar) bilinen PSNR iyileşmesini verir; Metal kernel çıktısı CPU referansıyla ±1 kod değerinde eşleşir (Metal test ortamında yoksa probe/CLI ile, Handoff'ta).
- [ ] Varsayılan yolda yakalama biçimi ve kodlayıcı ayarları değişmez.
- [ ] `ev=chroma_config`, `ev=chroma_stats` docs/LOGGING.md'de; knob docs/KNOBS.md'de.
- [ ] `./scripts/check.sh` geçer.
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

_(Ajan bitirince doldurur.)_
