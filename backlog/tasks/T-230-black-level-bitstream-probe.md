---
id: T-230
title: Black level lifted on the tablet (Mac 0 → tablet 16) — Mac-side bitstream probe (what Y values and VUI the encoder really emits)
status: review
phase: 6
owner: mac-host-dev
depends_on: []
decisions: []
files:
  - probes/color-range-probe/
  - probes/README.md
  - backlog/tasks/T-230-black-level-bitstream-probe.md
---

## Amaç

Kullanıcı 2026-10-05 ~00:00: terminalin siyah arka planı tablette gri görünüyor. Aynı anda alınan Mac `screencapture` ve tablet `screencap` karşılaştırması (`~/.cache/matebridge-tools/data/gray/`, ayrıca 2026-10-01 `~/.cache/matebridge-tools/idle_off_r0_{mac,tab}.png`):

| Mac RGB | Tablet RGB |
|---|---|
| 0,0,0 | 16,16,16 (1 Ekim'de de) |
| 16,16,16 | ~27–31 |
| 35,45,59 | 50,57,69 |
| 255,255,255 | 254–255 |

Siyah kalkık, beyaz doğru: kabaca `out ≈ 16 + in·239/255`. Saf "sınırlı aralığı tam diye göster" hatası beyazı da 235'e indirirdi, burada indirmiyor. Tablet ACodec: `color aspects (R:1(Full), P:1(BT709_5), M:1(BT709_5), T:2(SRGB)) dataspace 0x201`. Host: ScreenCaptureKit `420f` (tam aralık, `ScreenCapture.swift:54`), T-113 yeniden etiketleme 709/sRGB/709 (`HEVCEncoder.swift:272-291`), STREAM_CONFIG `full_range` → istemci `KEY_COLOR_RANGE` (`VideoRenderer.kt:367-369`).

Bu kart yalnız Mac tarafını ayırır: kodlayıcının ürettiği bit akışında siyah gerçekten Y=0 mı (tam aralık) yoksa Y=16 mı, ve VUI `video_full_range_flag` / renk açıklaması ne diyor. Tablet tarafı T-231'de.

## Bağlam

- Üretim koduna dokunma. Bağımsız bir Swift probu yaz (`probes/color-range-probe/`, diğer probların düzeninde). Probe, HEVCEncoder'ın oturum ayarlarını (profil, renk özellikleri, T-113 eki) birebir taklit eder ama sanal ekran ya da ScreenCaptureKit kullanmaz: bilinen bir desenle doldurulmuş `420f` `CVPixelBuffer` (Y = 0, 8, 16, 32, 64, 128, 235, 255 bantları; Cb = Cr = 128) üretir, VideoToolbox ile HEVC'ye kodlar ve şunları yazar:
  1. SPS VUI: `video_full_range_flag`, `colour_primaries`, `transfer_characteristics`, `matrix_coeffs` (ayrıştırıcı için `host-mac/Sources/MateBridgeHost/Video/VideoDump.swift` VUI koduna bakılabilir; kopyalanabilir, import edilemez);
  2. VideoToolbox ile Mac'te geri çözülmüş bantların Y değerleri (çözücüden `420f` ve `420v` isteyerek ayrı ayrı);
  3. aynı deneme T-113 eki olmadan (SCK'nın orijinal 709/709/709 ekleri) ve `420v` giriş ile.
- Yalnız komut satırı; **Mac'te pencere açma** (tablet Mac'in tek ekranı). Sanal ekran oluşturma (çalışan oturumu bozar).
- Sonucu card Handoff'a tablo olarak yaz: hangi yapılandırmada siyah bit akışında Y=0, hangisinde 16. Çıkan `.hevc` dosyalarını `~/.cache/matebridge-tools/data/color-probe/` altına koy (orkestratör bunları tablette çözdürebilir).

## Kabul kriterleri

- [x] `probes/color-range-probe/` derlenir, `./scripts/check.sh` geçer (probes README'ye bir satır).
- [x] Handoff'ta tablo: her yapılandırma × bant için VUI bayrakları ve Mac'te çözülmüş Y.
- [x] Sonuç cümlesi: "bit akışı doğru (Y=0, full=1) → sorun tablet tarafında" ya da "kodlayıcı siyahı 16'ya koyuyor / VUI yanlış → host düzeltmesi önerisi (tek satır, nerede)".

## Plan

1. `probes/color-range-probe/` SwiftPM paketi (hdr-probe düzeni): `ColorRangeProbeCore` (donanımdan bağımsız: bant düzeni, bant medyanı ölçümü, HEVC SPS VUI ayrıştırıcı — `MateBridgeCore/Video/HEVCSPS.swift` + `AnnexB.swift`'ten kopya, yapılandırma tablosu, argüman ayrıştırma) + unit testler; `color-range-probe` yürütülebilir hedefi (VideoToolbox).
2. Desen: 2800×1840 `CVPixelBuffer`, 8 dikey bant Y = 0, 8, 16, 32, 64, 128, 235, 255; Cb = Cr = 128. Giriş biçimi `420f` ya da `420v` (Y değerleri aynen yazılır; bant değeri "kod değeri"dir).
3. Kodlayıcı oturumu `HEVCEncoder.init`'i birebir taklit eder (`.fast` profil: HW açık, RealTime=false, reorder kapalı, HEVC Main AutoLevel, 60 fps, 30 Mbps + DataRateLimits 2×, MaxKeyFrameInterval, PrioritizeSpeed, oturum renkleri 709/sRGB/709).
4. Yapılandırmalar: `prod` (420f + SCK ekleri → T-113 yeniden etiket), `noretag` (420f + SCK ekleri 709/709/709 + sRGB CGColorSpace, olduğu gibi), `420v-retag`, `420v-noretag`, `420f-untagged` (ek yok). Her biri birkaç kare kodlanır (ilki anahtar kare).
5. Her yapılandırma için: SPS VUI alanları; `.hevc` (Annex-B) `~/.cache/matebridge-tools/data/color-probe/<config>.hevc`; VideoToolbox ile Mac'te geri çözme — çıktı biçimi `420f`, `420v` ve yerel (biçim istenmeden) — her bandın merkez bölgesindeki Y medyanı.
6. Ayrıca HW kodlayıcıyı kullandığı için kısa tutulur (yapılandırma başına birkaç kare); pencere, sanal ekran, SCK, adb yok.
7. Sonuç tablosu + yargı Handoff'a; probes/README'ye satır; `./scripts/check.sh`.

## Handoff

- **Commit:** `d820bfb` (probe + README), plan `7d68aa4`; bu Handoff ayrı commit.
- **Dosyalar:** `probes/color-range-probe/` (Package.swift, README.md, `ColorRangeProbeCore/{Bands,ProbeConfig,HEVCSPS,AnnexB}.swift`, `color-range-probe/main.swift`, testler), `probes/README.md` (bir satır), bu kart. `HEVCSPS.swift` ve `AnnexB.swift` host-mac'ten kopya (import değil).
- **check.sh:** ALL OK (yeni paket: build + 11 unit test).
- **Klipler:** `~/.cache/matebridge-tools/data/color-probe/{prod,noretag,420v-retag,420v-noretag,420f-untagged}.hevc` (Annex-B, VPS/SPS/PPS + 3 kare, 2800×1840, ilk kare IDR).

### Sonuç tablosu (2026-10-05, Mac mini M6, macOS 27, donanım HEVC kodlayıcısı `hardware=yes`)

"Kodlanmış Y" = VUI'ye uyan biçimde Mac'te çözülmüş luma (`full=1` → `420f`, `full=0` → `420v`), yani bit akışındaki örnek değerleri. Bant merkezlerinin medyanı; tüm bantlar düz (min = max), ilk kare ile son kare aynı.

| Yapılandırma | Giriş | Giriş ekleri | VUI full / prim / trc / matrix | Format ext FullRangeVideo | Kodlanmış Y (bant 0, 8, 16, 32, 64, 128, 235, 255) |
|---|---|---|---|---|---|
| **prod** (bugünkü üretim) | 420f | 709/sRGB/709 (+sRGB CGColorSpace) | **1 / 1 / 13 / 1** | 1 | **0**, 8, 16, 32, 64, 128, 235, 255 (birebir) |
| noretag (T-113 öncesi) | 420f | 709/709/709 (+CGColorSpace) | 1 / 1 / 13 / 1 | 1 | 0, 1, 14, 35, 73, 139, 237, 255 (VT renk dönüşümü; siyah yine 0) |
| 420v-retag | 420v | 709/sRGB/709 | 0 / 1 / 13 / 1 | 0 | 0, 8, 16, 32, 64, 128, 235, 255 (birebir; 420v'de siyah = 16) |
| 420v-noretag | 420v | 709/709/709 | 0 / 1 / 13 / 1 | 0 | 16, 16, 16, 30, 70, 137, 235, 235 (dönüşüm 16–235'e kırpıyor) |
| 420f-untagged | 420f | yok | 1 / 1 / 13 / 1 | 1 | 0, 8, 16, 32, 64, 128, 235, 255 (birebir) |

Aynı `prod` akışını Mac'te bilerek yanlış biçimde (`420v`, tam → sınırlı sıkıştırma) çözdürünce: 16, 23, 30, 43, 71, 126, 217, 234. Yerel (biçim istenmeden) çıktı: `prod` için `420f`, 420v girişleri için `420v`. Çözücü VUI'ye uyuyor.

### Sonuç

**Bit akışı doğru (Y=0, full=1, 709/sRGB/709): sorun tablet tarafında (T-231).** Kodlayıcı 420f girişte örnekleri değiştirmeden kodluyor (T-113 yeniden etiketleme sayesinde dönüşüm yok). VUI `video_full_range_flag=1`, `colour_primaries=1`, `transfer_characteristics=13`, `matrix_coeffs=1` yazıyor, tablet ACodec'in bildirdiği `R:1(Full) P:1 M:1 T:2(SRGB)` ile tutarlı. Host düzeltmesi önerilmiyor.

T-231 için ipucu (doğrulanmadı): tablette siyah tarafı (0→16, 16→27–31) Mac'teki tam→sınırlı sıkıştırmalı çözümle (0→16, 16→30) örtüşüyor. Beyaz ise örtüşmüyor (Mac'te 234, tablette 254–255). Tablet yolunda bir yerde tam aralık sınırlı aralık gibi sıkıştırılıyor ya da siyah yükseltiliyor (çözücü çıkışı, `KEY_COLOR_RANGE` ya da GPU/SurfaceFlinger dönüşümü). `prod.hevc` tablette çözdürülüp çıkış Y değerleri okunursa ayrım yapılabilir.

### Varsayımlar

- Sentetik `420f` IOSurface tamponu + SCK ekleri + T-113 yeniden etiketleme, SCK'nın gerçek tamponunun kodlayıcıdaki davranışını temsil ediyor (biçim ve ekler `EncodeBench.tagLikeScreenCaptureKit` ile aynı). Gerçek SCK karesi kodlanmadı (sanal ekran/SCK yasak).
- Oturum özellikleri `HEVCEncoder.init`'in `.fast` profilinden elle kopyalandı (RealTime=false, reorder kapalı, Main AutoLevel, 60 fps, 30 Mbps, DataRateLimits 2×/1 s, keyframe 300 s, PrioritizeSpeed, 709/sRGB/709). H.264 yolu denenmedi.
- Prob çalışırken MateBridge host süreci açıktı. Prob ona dokunmadı, yalnız donanım kodlayıcısını ~15 kare (birkaç ms) paylaştı.

### Gerçek donanımda doğrulanacaklar / test EDİLMEYENLER

- Tablet tarafı hiç denenmedi (adb/tablet yasak). Orkestratör `prod.hevc`'yi tablette MediaCodec ile çözdürüp siyah bandın çıkış Y/RGB değerine bakmalı (T-231).
- Gerçek SCK yakalamasının kodlanmış bit akışı bu probla ölçülmedi. Canlı akışın VUI'si istenirse host'un dump aracıyla (`VideoDump`, "SPS VUI (in the bitstream)" satırı) kontrol edilebilir. Bu kartta çalıştırılmadı (çalışan host'a dokunulmadı).

### Open questions

- Yok.
